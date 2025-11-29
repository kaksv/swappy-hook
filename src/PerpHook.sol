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


}
