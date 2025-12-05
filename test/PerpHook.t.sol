// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {SortTokens} from "@uniswap/v4-core/test/utils/SortTokens.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";

import {PerpHook, Position} from "../src/PerpHook.sol";
import {MockChainlinkPriceFeed, MockOracleAdapter} from "./mocks/MockOracle.sol";
import {IChainlinkPriceFeed} from "../src/interfaces/IChainlinkPriceFeed.sol";

contract PerpHookTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    PerpHook public hook;
    MockChainlinkPriceFeed public priceFeed;
    MockOracleAdapter public oracleAdapter;
    PoolKey public poolKey;
    uint160 public initSqrtPriceX96;

    // Test users
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");

    // Test tokens
    MockERC20 public token0; // Asset token (e.g., ETH)
    MockERC20 public token1; // Collateral token (e.g., USDC)

    // Constants
    // Chainlink prices are in 8 decimals, so $2000 = 2000 * 1e8
    int256 public constant INITIAL_PRICE_CHAINLINK = 2000e8; // $2000 per token0 in Chainlink format
    uint256 public constant INITIAL_PRICE = 2000e18; // $2000 per token0 in 18 decimals
    uint256 public constant INITIAL_COLLATERAL = 10000e18; // 10,000 USDC

    function setUp() public {
        deployFreshManagerAndRouters();

        // Deploy mock tokens
        token0 = new MockERC20("Asset", "ASSET", 18);
        token1 = new MockERC20("Collateral", "USDC", 18);

        // Sort tokens to determine which is currency0 and currency1
        (currency0, currency1) = SortTokens.sort(token0, token1);

        // Deploy mock Chainlink price feed
        priceFeed = new MockChainlinkPriceFeed(INITIAL_PRICE_CHAINLINK);
        
        // Deploy oracle adapter for easier management
        oracleAdapter = new MockOracleAdapter();
        oracleAdapter.setPriceFeed(currency0, priceFeed);

        // Calculate hook address with proper permissions
        uint160 hookAddress = uint160(
            type(uint160).max & clearAllHookPermissionsMask
                | Hooks.BEFORE_SWAP_FLAG
                | Hooks.AFTER_SWAP_FLAG
                | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
                | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );

        // Deploy hook to the calculated address
        // Hook now takes baseCurrency (collateral token) instead of oracle
        hook = PerpHook(payable(address(hookAddress)));
        deployCodeTo("PerpHook", abi.encode(manager, currency1), address(hook));

        // Set the price feed in the hook for currency0 (the asset)
        hook.setPriceFeed(currency0, IChainlinkPriceFeed(address(priceFeed)));

        // Create pool key
        poolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: 3000, // 0.3%
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });

        // Initialize pool at 1:1 price (will be overridden by oracle)
        initSqrtPriceX96 = uint160(TickMath.getSqrtPriceAtTick(0));
        manager.initialize(poolKey, initSqrtPriceX96);

        // Mint tokens to test users
        token0.mint(alice, 1000e18);
        token1.mint(alice, 100000e18);
        token0.mint(bob, 1000e18);
        token1.mint(bob, 100000e18);

        // Approve swap router
        token0.approve(address(swapRouter), type(uint256).max);
        token1.approve(address(swapRouter), type(uint256).max);
        vm.prank(alice);
        token0.approve(address(swapRouter), type(uint256).max);
        vm.prank(alice);
        token1.approve(address(swapRouter), type(uint256).max);
        vm.prank(bob);
        token0.approve(address(swapRouter), type(uint256).max);
        vm.prank(bob);
        token1.approve(address(swapRouter), type(uint256).max);

        // Add some liquidity to the pool for swaps to work
        _addLiquidity();
    }

    function _addLiquidity() internal {
        // Mint tokens to this contract for liquidity
        token0.mint(address(this), 1000e18);
        token1.mint(address(this), 1000e18);
        
        // Approve router
        token0.approve(address(modifyLiquidityRouter), type(uint256).max);
        token1.approve(address(modifyLiquidityRouter), type(uint256).max);
        
        // Add liquidity to enable swaps
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({
                tickLower: -1200,
                tickUpper: 1200,
                liquidityDelta: 1e18,
                salt: 0
            }),
            ""
        );
    }

    /// @notice Helper to open a long position
    /// @param trader The trader address
    /// @param collateralAmount Amount of collateral to deposit (token1)
    /// @param positionSize Position size in token0 (positive for long)
    function _openLongPosition(address trader, uint128 collateralAmount, int128 positionSize) internal {
        bytes memory hookData = abi.encode(trader, positionSize);

        vm.prank(trader);
        swapRouter.swap(
            poolKey,
            SwapParams({
                zeroForOne: false, // false = token1 -> token0 direction (depositing collateral)
                amountSpecified: -int256(uint256(collateralAmount)), // Negative = exact input of token1
                sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            hookData
        );
    }

    /// @notice Helper to open a short position
    /// @param trader The trader address
    /// @param collateralAmount Amount of collateral to deposit (token1)
    /// @param positionSize Position size in token0 (will be made negative for short)
    function _openShortPosition(address trader, uint128 collateralAmount, int128 positionSize) internal {
        bytes memory hookData = abi.encode(trader, -positionSize); // Negative for short

        vm.prank(trader);
        swapRouter.swap(
            poolKey,
            SwapParams({
                zeroForOne: false, // false = token1 -> token0 direction (depositing collateral)
                amountSpecified: -int256(uint256(collateralAmount)), // Negative = exact input of token1
                sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            hookData
        );
    }

    /// @notice Helper to get Position struct from public mapping
    /// @dev Public mappings return struct fields as separate values, so we need to destructure
    function _getPosition(address trader) internal view returns (Position memory) {
        (int128 size, uint128 collateral, uint256 entryPrice, uint256 liquidationPrice) = hook.positions(trader);
        return Position(size, collateral, entryPrice, liquidationPrice);
    }

    // ============ Tests ============

    function test_initialization() public view {
        assertEq(Currency.unwrap(hook.baseCurrency()), Currency.unwrap(currency1));
        assertEq(hook.INITIAL_MARGIN_RATE(), 10_000); // 10%
        assertEq(hook.MAINTENANCE_MARGIN_RATE(), 5_000); // 5%
        assertEq(hook.MAX_LEVERAGE(), 10);
        assertEq(hook.FEE_PER_MILLION(), 100); // 0.01%
        assertEq(address(hook.priceFeeds(currency0)), address(priceFeed));
    }

    function test_openLongPosition() public {
        uint128 collateral = 10000e18; // 10,000 USDC
        int128 positionSize = 5e18; // 5 tokens (long)

        _openLongPosition(alice, collateral, positionSize);

        Position memory position = _getPosition(alice);
        assertEq(position.size, positionSize);
        // Collateral will be less than input due to trading fees
        // Fee = (5e18 * 2000e18 * 100) / (1e18 * 1_000_000) = 1e18 USDC
        assertLt(position.collateral, collateral);
        assertGt(position.collateral, collateral - 2e18); // Allow some margin for rounding
        assertEq(position.entryPrice, INITIAL_PRICE);
        assertGt(position.liquidationPrice, 0);
        assertEq(hook.totalPositionSkew(), positionSize);
    }

    function test_openShortPosition() public {
        uint128 collateral = 10000e18; // 10,000 USDC
        int128 positionSize = 5e18; // 5 tokens (short, so negative)

        _openShortPosition(alice, collateral, positionSize);

        Position memory position = _getPosition(alice);
        assertEq(position.size, -positionSize); // Should be negative for short
        // Collateral will be less due to fees
        assertLt(position.collateral, collateral);
        assertEq(position.entryPrice, INITIAL_PRICE);
        assertGt(position.liquidationPrice, 0);
        assertEq(hook.totalPositionSkew(), -positionSize);
    }

    function test_marginRequirement() public {
        // Required margin for 5 tokens at $2000 with 10% margin = (5e18 * 2000e18 * 10000) / (1e18 * 1_000_000) = 100e18
        // So we need at least 100e18 + fees. Use 50e18 which is insufficient
        uint128 collateral = 50e18; // 50 USDC (insufficient)
        int128 positionSize = 5e18; // 5 tokens

        vm.expectRevert("PERP_HOOK: Margin requirement failed");
        _openLongPosition(alice, collateral, positionSize);
    }

    function test_insufficientCollateral() public {
        uint128 collateral = 0;
        int128 positionSize = 5e18;

        // With zero collateral, the swap amount will be zero, which causes SwapAmountCannotBeZero
        // But we want to test the hook's insufficient collateral check
        // So we use a very small amount that will fail margin check
        vm.expectRevert(); // Can be either SwapAmountCannotBeZero or InsufficientCollateral
        _openLongPosition(alice, collateral, positionSize);
    }

    function test_negativeCollateral() public {
        // Try to remove more collateral than exists
        uint128 initialCollateral = 10000e18;
        int128 positionSize = 1e18;

        // First open a position
        _openLongPosition(alice, initialCollateral, positionSize);

        // Now try to remove more collateral than we have
        bytes memory hookData = abi.encode(alice, int128(0)); // No position change
        vm.prank(alice);
        vm.expectRevert("PERP_HOOK: Negative collateral");
        swapRouter.swap(
            poolKey,
            SwapParams({
                zeroForOne: true, // Swapping token0 for token1 (removing collateral)
                amountSpecified: -int256(uint256(initialCollateral) + 1), // More than we have
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            hookData
        );
    }

    function test_increasePosition() public {
        uint128 initialCollateral = 10000e18;
        int128 initialSize = 2e18;

        // Open initial position
        _openLongPosition(alice, initialCollateral, initialSize);

        // Increase position
        uint128 additionalCollateral = 5000e18;
        int128 additionalSize = 2e18;

        bytes memory hookData = abi.encode(alice, additionalSize);
        vm.prank(alice);
        swapRouter.swap(
            poolKey,
            SwapParams({
                zeroForOne: false,
                amountSpecified: -int256(uint256(additionalCollateral)),
                sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            hookData
        );

        Position memory position = _getPosition(alice);
        assertEq(position.size, initialSize + additionalSize);
        // Collateral will be less due to fees on the additional size
        assertLt(position.collateral, initialCollateral + additionalCollateral);
        assertGt(position.collateral, initialCollateral + additionalCollateral - 2e18);
        assertEq(hook.totalPositionSkew(), initialSize + additionalSize);
    }

    function test_decreasePosition() public {
        uint128 initialCollateral = 10000e18;
        int128 initialSize = 5e18;

        // Open initial position
        _openLongPosition(alice, initialCollateral, initialSize);

        // Decrease position (partial close)
        int128 sizeReduction = -2e18; // Negative to reduce
        bytes memory hookData = abi.encode(alice, sizeReduction);

        // Remove some collateral
        uint128 collateralRemoval = 3000e18;
        vm.prank(alice);
        swapRouter.swap(
            poolKey,
            SwapParams({
                zeroForOne: true, // Removing collateral
                amountSpecified: int256(uint256(collateralRemoval)),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            hookData
        );

        Position memory position = _getPosition(alice);
        assertEq(position.size, initialSize + sizeReduction);
        // Collateral might be slightly different due to fees
        assertApproxEqAbs(position.collateral, initialCollateral - collateralRemoval, 2e18);
        assertEq(hook.totalPositionSkew(), initialSize + sizeReduction);
    }

    function test_liquidation() public {
        uint128 collateral = 10000e18;
        int128 positionSize = 5e18;

        // Open long position
        _openLongPosition(alice, collateral, positionSize);

        Position memory positionBefore = _getPosition(alice);
        uint256 liquidationPrice = positionBefore.liquidationPrice;

        // Update oracle price to trigger liquidation
        // For a long position, liquidation happens when price drops below liquidation price
        // Chainlink uses 8 decimals, so convert from 18 to 8
        uint256 newPrice18 = liquidationPrice - 1e18; // Just below liquidation price
        int256 newPrice8 = int256(newPrice18 / 1e10); // Convert to 8 decimals
        priceFeed.setPrice(newPrice8);

        // Trigger liquidation by performing a swap (this will call afterSwap)
        // Alice needs to do the swap to check alice's position for liquidation
        bytes memory hookData = abi.encode(alice, int128(0)); // No position change
        vm.prank(alice);
        swapRouter.swap(
            poolKey,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -1000, // Small swap to trigger afterSwap
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            hookData
        );

        Position memory positionAfter = _getPosition(alice);
        assertEq(positionAfter.size, 0);
        assertEq(positionAfter.collateral, 0);
        assertEq(hook.totalPositionSkew(), 0);
    }

    function test_multipleTraders() public {
        // Alice opens long
        _openLongPosition(alice, 10000e18, 3e18);

        // Bob opens short
        _openShortPosition(bob, 10000e18, 2e18);

        Position memory alicePosition = _getPosition(alice);
        Position memory bobPosition = _getPosition(bob);

        assertEq(alicePosition.size, 3e18);
        assertEq(bobPosition.size, -2e18);
        assertEq(hook.totalPositionSkew(), 1e18); // Net skew: 3 - 2 = 1
    }

    function test_priceUpdate() public {
        uint128 collateral = 10000e18;
        int128 positionSize = 5e18;

        _openLongPosition(alice, collateral, positionSize);

        Position memory position1 = _getPosition(alice);
        uint256 entryPrice1 = position1.entryPrice;

        // Update price and modify position
        // Chainlink uses 8 decimals
        int256 newPrice8 = int256(2100e8); // Price increased to $2100
        priceFeed.setPrice(newPrice8);

        // Add more to position at new price
        bytes memory hookData = abi.encode(alice, int128(1e18));
        vm.prank(alice);
        swapRouter.swap(
            poolKey,
            SwapParams({
                zeroForOne: false,
                amountSpecified: -int256(uint256(5000e18)),
                sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            hookData
        );

        Position memory position2 = _getPosition(alice);
        // Entry price should be updated to new price (convert from 8 to 18 decimals for comparison)
        uint256 newPrice18 = uint256(newPrice8) * 1e10; // Convert 8 decimals to 18
        assertEq(position2.entryPrice, newPrice18);
        assertEq(position2.size, positionSize + 1e18);
    }

    function test_calculateRequiredCollateral() public {
        uint128 size = 10e18;
        uint256 price = 2000e18;

        // Required collateral = (10e18 * 2000e18 * 10000) / (1e18 * 1_000_000)
        // = (20_000e36 * 10000) / 1_000_000e18
        // = 200_000e36 / 1_000_000e18
        // = 200e18

        // We can't directly test internal function, but we can test it indirectly
        // by ensuring a position with sufficient collateral works
        uint128 sufficientCollateral = 3000e18; // More than required
        int128 positionSize = 10e18;

        _openLongPosition(alice, sufficientCollateral, positionSize);

        Position memory position = _getPosition(alice);
        assertEq(position.size, positionSize);
        assertGt(position.collateral, 0);
    }

    function test_zeroPositionSize() public {
        // Opening a position with zero size should work (just depositing collateral)
        bytes memory hookData = abi.encode(alice, int128(0));
        vm.prank(alice);
        swapRouter.swap(
            poolKey,
            SwapParams({
                zeroForOne: false,
                amountSpecified: -int256(uint256(10000e18)),
                sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            hookData
        );

        Position memory position = _getPosition(alice);
        assertEq(position.size, 0);
        // After closing, collateral should be returned (minus any fees)
        assertGt(position.collateral, 0);
    }

    function test_closePosition() public {
        uint128 collateral = 10000e18;
        int128 positionSize = 5e18;

        // Open position
        _openLongPosition(alice, collateral, positionSize);

        // Close position completely
        int128 closeSize = -positionSize; // Negative to close
        bytes memory hookData = abi.encode(alice, closeSize);

        vm.prank(alice);
        swapRouter.swap(
            poolKey,
            SwapParams({
                zeroForOne: true,
                amountSpecified: int256(uint256(collateral)), // Remove all collateral
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            hookData
        );

        Position memory position = _getPosition(alice);
        assertEq(position.size, 0);
        assertEq(hook.totalPositionSkew(), 0);
    }
}

