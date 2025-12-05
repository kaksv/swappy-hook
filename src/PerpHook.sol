// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// Imports for Uniswap V4 environment
import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary, toBeforeSwapDelta} from "v4-core/types/BeforeSwapDelta.sol";
import {SafeCast} from "v4-core/libraries/SafeCast.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";
import {IChainlinkPriceFeed} from "./interfaces/IChainlinkPriceFeed.sol";

// Struct to hold a trader's position data
struct Position {
    int128 size;            // Token 0 equivalent size of the position (long/short)
    uint128 collateral;     // Collateral deposited in token 1 (e.g., USDC)
    uint256 entryPrice;     // Price at which the position was opened/modified
    uint256 liquidationPrice; // The price that triggers liquidation
}

/// @title PerpHook - Perpetual Exchange Hook for Uniswap V4
/// @notice Implements a perpetual exchange using oracle-based pricing (Chainlink)
/// @dev Inspired by GMX V2's approach: pool for collateral, oracle for pricing
contract PerpHook is BaseHook {
    using SafeCast for int256;
    using SafeCast for uint256;

    // --- Chainlink Oracle Configuration ---
    // Mapping: Currency => Chainlink price feed address
    // For token0 (asset), we need a price feed to token1 (collateral)
    mapping(Currency => IChainlinkPriceFeed) public priceFeeds;
    
    // Base currency (collateral token, e.g., USDC)
    Currency public immutable baseCurrency;

    // --- Risk & Accounting Parameters ---
    uint256 public constant INITIAL_MARGIN_RATE = 10_000; // 10% (in basis points, 1e6 = 100%)
    uint256 public constant MAINTENANCE_MARGIN_RATE = 5_000; // 5%
    uint256 public constant MAX_LEVERAGE = 10; // 10x
    uint256 public constant FEE_PER_MILLION = 100; // 0.01% trading fee (100 / 1,000,000)
    uint256 public constant PRICE_PRECISION = 1e18; // Price precision (18 decimals)

    // --- State Storage ---
    // Trader Address => Position Data
    mapping(address => Position) public positions;

    // The Pool's total skew (long vs. short size imbalance)
    // Used to calculate dynamic funding rates and skew fees.
    int128 public totalPositionSkew;

    // Errors
    error InvalidPriceFeed();
    error StalePrice();
    error InvalidPosition();
    error InsufficientCollateral();
    error MarginRequirementFailed();
    error NegativeCollateral();

    // Events
    event PositionOpened(address indexed trader, int128 size, uint128 collateral, uint256 entryPrice);
    event PositionClosed(address indexed trader);
    event PositionLiquidated(address indexed trader, uint256 collateralSeized);

    constructor(
        IPoolManager _poolManager,
        Currency _baseCurrency
    ) BaseHook(_poolManager) {
        baseCurrency = _baseCurrency;
    }

    /// @notice Set the Chainlink price feed for an asset currency
    /// @param assetCurrency The asset currency (token0)
    /// @param priceFeed The Chainlink price feed address
    function setPriceFeed(Currency assetCurrency, IChainlinkPriceFeed priceFeed) external {
        // In production, add access control
        priceFeeds[assetCurrency] = priceFeed;
    }

    // Base Function for activating the flags being used in the PerpHook
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return
            Hooks.Permissions({
                beforeInitialize: false,
                afterInitialize: false,
                beforeAddLiquidity: false,
                afterAddLiquidity: false,
                beforeRemoveLiquidity: false,
                afterRemoveLiquidity: false,
                beforeSwap: true,
                afterSwap: true,
                beforeDonate: false,
                afterDonate: false,
                beforeSwapReturnDelta: true,
                afterSwapReturnDelta: true,
                afterAddLiquidityReturnDelta: false,
                afterRemoveLiquidityReturnDelta: false
            });
    }

    /// @notice Get mark price from Chainlink oracle
    /// @param assetCurrency The asset currency (token0)
    /// @return markPrice The current mark price in 18 decimals (asset/baseCurrency)
    function getMarkPrice(Currency assetCurrency) public view returns (uint256 markPrice) {
        IChainlinkPriceFeed priceFeed = priceFeeds[assetCurrency];
        if (address(priceFeed) == address(0)) revert InvalidPriceFeed();

        (, int256 price, , uint256 updatedAt, ) = priceFeed.latestRoundData();
        
        // Check for stale price (older than 1 hour)
        if (block.timestamp - updatedAt > 3600) revert StalePrice();
        
        // Price should be positive
        if (price <= 0) revert InvalidPriceFeed();

        uint8 decimals = priceFeed.decimals();
        
        // Convert to 18 decimals
        if (decimals == 18) {
            markPrice = uint256(price);
        } else if (decimals < 18) {
            markPrice = uint256(price) * (10 ** (18 - decimals));
        } else {
            markPrice = uint256(price) / (10 ** (decimals - 18));
        }
    }

    /// @notice Calculate required collateral in the collateral token for a given position size
    /// @param _size Absolute position size in token0
    /// @param _price Mark price (token0/token1 in 18 decimals)
    /// @return Required collateral in token1
    function calculateRequiredCollateral(uint128 _size, uint256 _price) internal pure returns (uint128) {
        // Collateral = (Size * Price * Initial Margin Rate) / (1,000,000 * PRICE_PRECISION)
        // This ensures we have enough collateral for the margin requirement
        uint256 positionValue = FullMath.mulDiv(_size, _price, PRICE_PRECISION);
        uint256 requiredCollateral = FullMath.mulDiv(positionValue, INITIAL_MARGIN_RATE, 1_000_000);
        return uint128(requiredCollateral);
    }

    /// @notice Calculates the liquidation price based on the current position
    /// @param _position The current position state
    /// @param _currentPrice The current mark price
    /// @param _isLong True if the position is long
    /// @return The liquidation price
    function calculateLiquidationPrice(
        Position memory _position,
        uint256 _currentPrice,
        bool _isLong
    ) internal pure returns (uint256) {
        if (_position.size == 0) return 0;

        // Simplified liquidation price calculation
        // For long: liquidation when price drops below (entryPrice * (1 - maintenanceMargin))
        // For short: liquidation when price rises above (entryPrice * (1 + maintenanceMargin))
        if (_isLong) {
            // Long position liquidates when price drops too much
            return (_currentPrice * (1_000_000 - MAINTENANCE_MARGIN_RATE)) / 1_000_000;
        } else {
            // Short position liquidates when price rises too much
            return (_currentPrice * (1_000_000 + MAINTENANCE_MARGIN_RATE)) / 1_000_000;
        }
    }

    /// @notice Internal helper to update position state
    function _updatePosition(
        address sender,
        Position storage currentPosition,
        int256 collateralDelta,
        int128 positionSizeDelta,
        uint256 markPrice
    ) internal {
        // Calculate new collateral
        int256 newCollateralInt = int256(uint256(currentPosition.collateral)) + collateralDelta;
        if (newCollateralInt < 0) revert NegativeCollateral();
        uint256 newCollateral = uint256(newCollateralInt);
        int128 newSize = currentPosition.size + positionSizeDelta;

        // Validate position
        if (newSize != 0 && newCollateral == 0) revert InsufficientCollateral();

        // Calculate required margin
        uint128 absNewSize = uint128(uint256(int256(newSize >= 0 ? newSize : -newSize)));
        uint128 requiredMargin = calculateRequiredCollateral(absNewSize, markPrice);
        if (newCollateral < requiredMargin && newSize != 0) {
            revert MarginRequirementFailed();
        }

        // Calculate and deduct trading fee
        if (positionSizeDelta != 0) {
            uint128 absSizeDelta = uint128(uint256(int256(positionSizeDelta >= 0 ? positionSizeDelta : -positionSizeDelta)));
            uint256 sizeValue = FullMath.mulDiv(absSizeDelta, markPrice, PRICE_PRECISION);
            uint256 tradeFee = FullMath.mulDiv(sizeValue, FEE_PER_MILLION, 1_000_000);
            if (tradeFee > newCollateral) revert InsufficientCollateral();
            newCollateral -= tradeFee;
        }

        // Update position
        bool isNewPosition = currentPosition.size == 0 && newSize != 0;
        bool isClosingPosition = currentPosition.size != 0 && newSize == 0;

        currentPosition.collateral = uint128(newCollateral);
        currentPosition.size = newSize;
        currentPosition.entryPrice = markPrice;
        currentPosition.liquidationPrice = calculateLiquidationPrice(
            currentPosition,
            markPrice,
            newSize > 0
        );

        totalPositionSkew += positionSizeDelta;

        if (isNewPosition) {
            emit PositionOpened(sender, newSize, uint128(newCollateral), markPrice);
        } else if (isClosingPosition) {
            emit PositionClosed(sender);
        }
    }

    /**
     * @notice Core trading & margin logic.
     * @dev Runs BEFORE the standard AMM swap and overrides V4 pricing using Chainlink oracle.
     */
    function _beforeSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        bytes calldata hookData
    ) internal override returns (bytes4, BeforeSwapDelta, uint24) {
        uint256 markPrice = getMarkPrice(key.currency0);
        
        // Decode hookData: (address trader, int128 positionSizeDelta)
        // If trader is not provided, use sender (for backward compatibility)
        address trader = sender;
        int128 positionSizeDelta;
        if (hookData.length > 0) {
            if (hookData.length >= 52) {
                // Has both trader and positionSizeDelta
                (trader, positionSizeDelta) = abi.decode(hookData, (address, int128));
            } else {
                // Only positionSizeDelta (backward compatibility)
                positionSizeDelta = abi.decode(hookData, (int128));
            }
        }

        // Calculate collateral delta from swap parameters
        // For perpetual exchanges:
        // - zeroForOne = false: depositing collateral (token1 input, negative amountSpecified)
        //   From hook perspective: adding collateral, so collateralDelta should be POSITIVE
        // - zeroForOne = true: withdrawing collateral (token1 output, positive amountSpecified)
        //   From hook perspective: removing collateral, so collateralDelta should be NEGATIVE
        // amountSpecified is negative for exact input, positive for exact output
        int256 collateralDelta;
        if (!params.zeroForOne) {
            // Depositing: amountSpecified is negative (exact input), but we're adding collateral
            collateralDelta = -params.amountSpecified; // Make it positive
        } else {
            // Withdrawing: amountSpecified is positive (exact output), but we're removing collateral
            collateralDelta = -params.amountSpecified; // Make it negative
        }

        Position storage currentPosition = positions[trader];
        _updatePosition(trader, currentPosition, collateralDelta, positionSizeDelta, markPrice);

        return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    /**
     * @notice Handles settlement, PnL realization, and funding rate application.
     * Runs AFTER the standard AMM swap (which moved collateral) is executed.
     */
    function _afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta, // The final balance change after the swap
        bytes calldata hookData
    ) internal override returns (bytes4, int128) {
        // 1. Get current Mark Price
        uint256 markPrice = getMarkPrice(key.currency0);
        
        // Decode trader from hookData (same as in beforeSwap)
        address trader = sender;
        if (hookData.length >= 52) {
            (trader,) = abi.decode(hookData, (address, int128));
        }
        
        Position storage currentPosition = positions[trader];

        // 2. Check for liquidation
        // For long positions: liquidate if price drops below liquidation price
        // For short positions: liquidate if price rises above liquidation price
        bool shouldLiquidate = false;
        if (currentPosition.size > 0) {
            // Long position
            shouldLiquidate = markPrice <= currentPosition.liquidationPrice;
        } else if (currentPosition.size < 0) {
            // Short position
            shouldLiquidate = markPrice >= currentPosition.liquidationPrice;
        }

        int256 settlementDelta = 0;

        if (shouldLiquidate && currentPosition.size != 0) {
            // Trigger liquidation
            int128 sizeBefore = currentPosition.size;
            uint128 collateralBefore = currentPosition.collateral;

            // Seize collateral (liquidation penalty)
            settlementDelta = -int256(uint256(collateralBefore));

            // Reset position
            currentPosition.size = 0;
            currentPosition.collateral = 0;
            currentPosition.liquidationPrice = 0;

            // Update skew
            totalPositionSkew -= sizeBefore;

            emit PositionLiquidated(sender, collateralBefore);
        }

        // 3. Apply funding rate (simplified - in production, calculate based on skew and time)
        // For now, funding payment is 0
        // settlementDelta already accounts for liquidation

        // 4. Return settlement delta (in token1/collateral)
        // Negative = hook takes tokens (liquidation penalty)
        // Positive = hook gives tokens (funding rebate, PnL)
        return (this.afterSwap.selector, settlementDelta.toInt128());
    }
}
