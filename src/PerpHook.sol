// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// Imports for uniswap-v4 environments
import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
// import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";

import {PoolId} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";

import {Currency} from "v4-core/types/Currency.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {SafeCast} from "v4-core/libraries/SafeCast.sol";

// import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {TickMath} from "v4-core/libraries/TickMath.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";

import {FixedPointMathLib} from "solmate/src/utils/FixedPointMathLib.sol";


// Mock interface for an external price oracle (e.g Chainlink data streams or Uniswap TWAP and onchain data)
interface IExternalPriceOracle {
    function getMarkPrice(Currency token0, Currency token1) external view returns (uint256);
}

// Struct to hold a trader's position data
struct Position {
    int128 size;            // Token 0 equivalent size of the position (long/short)
    uint128 collateral;     // Collateral deposited in token 1 (e.g., USDC)
    uint256 entryPrice;     // Price at which the position was opened/modified
    uint256 liquidationPrice; // The price that triggers liquidation
}

contract PerpHook is BaseHook {
    // function getMarkPrice(Currency token0, Currency token1) external view returns (uint256);
    using SafeCast for int256;
    using SafeCast for uint256;

    // The pool will be TOKENA/COLLATERAL_TOKEN (e.g., ETH/USDC)
        IExternalPriceOracle public immutable oracle;

    // --- Risk & Accounting Parameters ---
    uint256 public constant INITIAL_MARGIN_RATE = 10_000; // 10%
    uint256 public constant MAINTENANCE_MARGIN_RATE = 5_000; // 5%
    uint256 public constant MAX_LEVERAGE = 10; // 10x
    uint256 public constant FEE_PER_MILLION = 100; // 0.01% trading fee

    // --- State Storage (Key inspiration from GMX/Hyperliquid) ---
    // Trader Address => Position Data
    mapping(address => Position) public positions;

    // The Pool's total skew (long vs. short size imbalance)
    // Used to calculate dynamic funding rates and skew fees.
    int128 public totalPositionSkew; 

    // Errors --- Will update them whenever need arises.
    constructor(IPoolManager _poolManager, IExternalPriceOracle _oracle) BaseHook(_poolManager) {
        poolManager = _poolManager;
        oracle = _oracle;
    }

    // Base Function for activating the flags being used in the PerpHook
    function getHookPermissions()
        public
        pure
        override
        returns (Hooks.Permissions memory)
    {
        return
            Hooks.Permissions({
                beforeInitialize: false,
                afterInitialize: true,
                beforeAddLiquidity: false,
                afterAddLiquidity: false,
                beforeRemoveLiquidity: false,
                afterRemoveLiquidity: false,
                beforeSwap: true,
                afterSwap: true,
                beforeDonate: false,
                afterDonate: false,
                beforeSwapReturnDelta: false,
                afterSwapReturnDelta: false,
                afterAddLiquidityReturnDelta: false,
                afterRemoveLiquidityReturnDelta: false
            });
    }

        function calculateRequiredCollateral(uint128 _size, uint256 _price) internal pure returns (uint128) {
        // Collateral = (Size * Price) / (Max Leverage)
        // Simplified: (Size * Price * Initial Margin Rate) / 1000000
        uint256 value = FullMath.mulDiv(_size, _price, 10**18); // Use 10**18 for fixed point math if needed
        return uint128(FullMath.mulDiv(value, INITIAL_MARGIN_RATE, 1_000_000));
    }

        /**
     * @notice Calculates the liquidation price based on the current position.
     * @param _position The current position state.
     * @param _currentPrice The current mark price.
     * @param _isLong True if the position is long.
     * @return The liquidation price.
     */
    function calculateLiquidationPrice(Position memory _position, uint256 _currentPrice, bool _isLong) internal view returns (uint256) {
        // This is complex math, highly simplified here for illustration.
        // It should account for PnL, Maintenance Margin, and pool losses.
        return _isLong
            ? (_currentPrice * (10_000 - MAINTENANCE_MARGIN_RATE)) / 10_000 // Placeholder logic
            : (_currentPrice * (10_000 + MAINTENANCE_MARGIN_RATE)) / 10_000; // Placeholder logic
    }

        /**
     * @notice Executes the core trading and accounting logic.
     * Runs BEFORE the standard AMM swap is executed.
     * The 'swap' will be used to move collateral/settlement tokens, not for AMM price discovery.
     */
    function _beforeSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        bytes calldata /*hookData*/
    ) external override onlyPoolManager returns (bytes4, int256) {
        // 1. Get Mark Price from Oracle (Pricing inspired by GMX V2)
        uint256 markPrice = oracle.getMarkPrice(key.currency0, key.currency1);

        // 2. Decode the Intent (The 'amountSpecified' field in params is repurposed for position size)
        // For simplicity, we assume params.amountSpecified is the desired collateral amount change (positive for adding, negative for removing)
        int256 collateralDelta = params.amountSpecified;
        
        // Assume hookData contains the desired position size change (in Token 0 terms)
        (int128 positionSizeDelta) = abi.decode(params.data, (int128));

        // 3. Margin & Risk Check (Inspired by Hyperliquid/Paradex risk controls)
        Position storage currentPosition = positions[sender];
        
        // Calculate the value of the new margin/collateral
        uint256 newCollateral = uint256(int256(currentPosition.collateral) + collateralDelta);
        int128 newSize = currentPosition.size + positionSizeDelta;
        require(newCollateral > 0 || newSize == 0, "PERP_HOOK: Insufficient Collateral");

        // Calculate required margin for new position (Highly simplified check)
        uint256 requiredMargin = calculateRequiredCollateral(uint128(newSize), markPrice);
        require(newCollateral >= requiredMargin, "PERP_HOOK: Margin requirement failed");

        // 4. Update Position State
        currentPosition.collateral = uint128(newCollateral);
        currentPosition.size = newSize;
        currentPosition.entryPrice = markPrice;
        currentPosition.liquidationPrice = calculateLiquidationPrice(currentPosition, markPrice, newSize > 0);

        // Update overall market skew
        totalPositionSkew += positionSizeDelta;

        // 5. Calculate and Charge Fees (Inspired by GMX V2 fee structure)
        // Fee = abs(positionSizeDelta) * MarkPrice * FEE_PER_MILLION / 1,000,000
        uint256 rawSizeValue = FullMath.mulDiv(uint256(positionSizeDelta < 0 ? -positionSizeDelta : positionSizeDelta), markPrice, 10**18);
        uint256 tradeFee = FullMath.mulDiv(rawSizeValue, FEE_PER_MILLION, 1_000_000);

        // The hook needs to instruct the PoolManager to take the collateral and the fee.
        // We adjust the delta to account for the charged fee.
        // The default swap logic will execute using 'collateralDelta', but the fee is extracted
        // from the Pool Manager's transient storage using a custom delta return.
        
        // For this conceptual hook, we assume all fee payment is token 1 (collateral token)
        // This is complex in V4 as the core swap calculates the final balance change (delta).
        // In a real V4 hook, the fee would be charged by manipulating the transient storage deltas.
        
        // Here, we simply ensure the swap's collateral movement covers the required margin change.
        // We assume the original swap params were only for the collateral change, which is moved now.

        // The required return is a bytes4 selector and a custom delta. 
        // We will return a zero delta here and manage all accounting in the position storage.
        // The actual collateral move happens via the standard V4 flash accounting process.
        // The core V4 swap logic will execute, but its concentrated liquidity calculation is effectively ignored
        // since pricing is done via the oracle *before* the swap. The swap just moves the tokens.
        
        return (this.beforeSwap.selector, 0); // No custom delta required for this simplified flow
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
        bytes calldata /*hookData*/
    ) external override onlyPoolManager returns (bytes4, int128) {
        // 1. Get current Mark Price
        uint256 markPrice = oracle.getMarkPrice(key.currency0, key.currency1);
        Position storage currentPosition = positions[sender];
        
        // 2. Realize PnL (If position is closed or reduced)
        // Since this is a perpetual hook, PnL is realized when the position size (currentPosition.size) is changed.
        // Since we updated the position in beforeSwap, here we can apply funding rates.

        // 3. Apply Funding Rate (Core Perpetual Mechanism)
        // Funding Rate = f(Mark Price - Pool Price, totalPositionSkew)
        // We skip complex funding rate math here but assume it's calculated off-chain by keepers 
        // or a simpler on-chain calculation and applied periodically.
        
        // For demonstration, let's pretend we calculated a funding payment (in collateral token)
        int256 fundingPayment = 0; // In token 1 (collateral)

        // 4. Liquidation Check (This should ideally be a separate public function called by a keeper)
        // Check if the current PnL + margin is below maintenance margin
        if (markPrice <= currentPosition.liquidationPrice && currentPosition.size > 0) {
            // Trigger liquidation: set position size to zero, take collateral (liquidation fee).
            currentPosition.size = 0;
            // Charge the remaining collateral as liquidation penalty and transfer it to the LP pool.
            fundingPayment -= int256(currentPosition.collateral); 
            currentPosition.collateral = 0;
            totalPositionSkew -= currentPosition.size;
            // Emit a Liquidation event
        }
        
        // 5. Final Adjustment (If funding or PnL settlement happened)
        // This is the custom delta returned to the PoolManager.
        // Positive token 1 means the Hook gives back token 1 (rebate/PnL).
        // Negative token 1 means the Hook takes token 1 (funding payment/fees).
        
        // Create the final balance delta: (amount0, amount1)
        // Since we are only using token 1 (collateral) for PnL/funding/fees, amount0 is 0.
        int256 token1Delta = fundingPayment; 
        
        // Return the required selector and the token1 delta packed into the return value
        return (this.afterSwap.selector, token1Delta.toInt128()); 
    }


}
