// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {PerpHook} from "../src/PerpHook.sol";

/// @notice Script to initialize a pool with PerpHook after deployment
/// @dev Run this after deploying PerpHook to create a pool
contract InitializePool is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        // Get addresses from environment or update these
        address poolManagerAddress = vm.envAddress("POOL_MANAGER_ADDRESS");
        address hookAddress = vm.envAddress("HOOK_ADDRESS");
        address assetToken = vm.envAddress("ASSET_TOKEN"); // e.g., WETH
        address collateralToken = vm.envAddress("COLLATERAL_TOKEN"); // e.g., USDC

        IPoolManager poolManager = IPoolManager(poolManagerAddress);
        PerpHook hook = PerpHook(payable(hookAddress));

        console.log("=== Initializing Pool ===");
        console.log("PoolManager:", address(poolManager));
        console.log("Hook:", address(hook));
        console.log("Asset Token:", assetToken);
        console.log("Collateral Token:", collateralToken);

        // Sort tokens (currency0 < currency1)
        Currency currency0;
        Currency currency1;
        if (assetToken < collateralToken) {
            currency0 = Currency.wrap(assetToken);
            currency1 = Currency.wrap(collateralToken);
        } else {
            currency0 = Currency.wrap(collateralToken);
            currency1 = Currency.wrap(assetToken);
        }

        // Create pool key
        PoolKey memory poolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: 3000, // 0.3% fee
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });

        // Initialize pool at 1:1 price (oracle will override pricing)
        uint160 sqrtPriceX96 = uint160(TickMath.getSqrtPriceAtTick(0));
        
        console.log("Initializing pool...");
        poolManager.initialize(poolKey, sqrtPriceX96);
        
        console.log("Pool initialized successfully!");
        console.log("Pool ID:", uint256(keccak256(abi.encode(poolKey))));

        vm.stopBroadcast();
    }
}

