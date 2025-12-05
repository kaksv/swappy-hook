// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {HookMiner} from "../lib/v4-periphery/src/utils/HookMiner.sol";
import {PerpHook} from "../src/PerpHook.sol";
import {IChainlinkPriceFeed} from "../src/interfaces/IChainlinkPriceFeed.sol";

/// @notice Deployment script for PerpHook on Ethereum Sepolia
/// @dev Deploys PerpHook with proper address mining for hook flags
contract DeployPerpHook is Script {
    // CREATE2 Deployer Proxy address (same for all chains)
    address constant CREATE2_DEPLOYER = address(0x4e59b44847b379578588920cA78FbF26c0B4956C);

    // Uniswap V4 PoolManager on Sepolia
    // NOTE: Update this with the actual PoolManager address when Uniswap V4 is deployed to Sepolia
    // You can also set this via environment variable: POOL_MANAGER_ADDRESS
    IPoolManager public poolManager;

    // Chainlink Price Feed addresses on Sepolia
    // ETH/USD Price Feed on Sepolia: https://docs.chain.link/data-feeds/price-feeds/addresses?network=ethereum&page=1#sepolia-testnet
    address constant ETH_USD_PRICE_FEED = address(0x694AA1769357215DE4FAC081bf1f309aDC325306); // ETH/USD on Sepolia
    
    // USDC address on Sepolia (commonly used as collateral)
    // NOTE: Update with actual USDC address on Sepolia if different
    address constant USDC_SEPOLIA = address(0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238); // USDC on Sepolia

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        // Get PoolManager address from env or use default
        try vm.envAddress("POOL_MANAGER_ADDRESS") returns (address pm) {
            poolManager = IPoolManager(pm);
        } catch {
            // Fallback to default (update this with actual Sepolia address)
            poolManager = IPoolManager(address(0xE03A1074c86CFeDd5C142C4F04F1a1536e203543));
        }

        console.log("=== Deploying PerpHook to Sepolia ===");
        console.log("Deployer:", msg.sender);
        console.log("PoolManager:", address(poolManager));

        // Define hook permissions flags
        uint160 flags = uint160(
            Hooks.BEFORE_SWAP_FLAG |
            Hooks.AFTER_SWAP_FLAG |
            Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG |
            Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );

        console.log("Mining hook address with flags:", flags);

        // Prepare constructor arguments
        Currency baseCurrency = Currency.wrap(USDC_SEPOLIA);
        bytes memory constructorArgs = abi.encode(poolManager, baseCurrency);

        // Mine a salt that will produce a hook address with the correct flags
        (address hookAddress, bytes32 salt) = HookMiner.find(
            CREATE2_DEPLOYER,
            flags,
            type(PerpHook).creationCode,
            constructorArgs
        );

        console.log("Found hook address:", hookAddress);
        console.log("Salt:", vm.toString(salt));

        // Deploy the hook using CREATE2
        console.log("Deploying PerpHook...");
        PerpHook hook = new PerpHook{salt: salt}(poolManager, baseCurrency);
        
        require(address(hook) == hookAddress, "Hook address mismatch");
        console.log("PerpHook deployed at:", address(hook));

        // Set up Chainlink price feed for ETH
        // NOTE: You'll need to deploy or use an existing Chainlink price feed
        // For ETH/USDC, you might need to use ETH/USD feed and convert
        console.log("\n=== Setting up Price Feeds ===");
        console.log("ETH/USD Price Feed:", ETH_USD_PRICE_FEED);
        
        // Set price feed for ETH (assuming ETH/WETH is currency0 in your pool)
        // NOTE: Update this with the actual WETH address on Sepolia
        // WETH on Sepolia: typically 0x7b79995e5f793A07Bc00c21412e50Ecae098E7f9
        address WETH_SEPOLIA = address(0x7b79995e5f793A07Bc00c21412e50Ecae098E7f9); // Update if different
        Currency ethCurrency = Currency.wrap(WETH_SEPOLIA);
        IChainlinkPriceFeed ethPriceFeed = IChainlinkPriceFeed(ETH_USD_PRICE_FEED);
        
        // Note: In production, you might want to use a multi-sig or timelock for setPriceFeed
        hook.setPriceFeed(ethCurrency, ethPriceFeed);
        console.log("Price feed set for ETH at address:", WETH_SEPOLIA);

        console.log("\n=== Deployment Summary ===");
        console.log("Hook Address:", address(hook));
        console.log("Base Currency (Collateral):", Currency.unwrap(baseCurrency));
        console.log("PoolManager:", address(poolManager));
        console.log("\n=== Environment Variables for Next Steps ===");
        console.log("export HOOK_ADDRESS=", address(hook));
        console.log("export POOL_MANAGER_ADDRESS=", address(poolManager));
        console.log("\nNext steps:");
        console.log("1. Verify the contract on Etherscan");
        console.log("2. Run InitializePool.s.sol to create a pool");
        console.log("3. Set additional price feeds for other assets if needed");

        vm.stopBroadcast();
    }

    /// @notice Helper function to verify hook deployment
    function verifyDeployment(address hookAddress) external view {
        PerpHook hook = PerpHook(hookAddress);
        console.log("Hook Base Currency:", Currency.unwrap(hook.baseCurrency()));
        console.log("Hook INITIAL_MARGIN_RATE:", hook.INITIAL_MARGIN_RATE());
        console.log("Hook MAINTENANCE_MARGIN_RATE:", hook.MAINTENANCE_MARGIN_RATE());
        console.log("Hook MAX_LEVERAGE:", hook.MAX_LEVERAGE());
        console.log("Hook FEE_PER_MILLION:", hook.FEE_PER_MILLION());
    }
}

