# PerpHook Deployment Guide for Ethereum Sepolia

## Prerequisites

1. **Environment Setup**
   - Install Foundry: `curl -L https://foundry.paradigm.xyz | bash`
   - Install dependencies: `forge install`
   - Get Sepolia ETH from a faucet

2. **Required Environment Variables**
   Create a `.env` file in the root directory:
   ```bash
   PRIVATE_KEY=your_private_key_here
   SEPOLIA_RPC_URL=https://sepolia.infura.io/v3/YOUR_INFURA_KEY
   # Or use Alchemy: https://eth-sepolia.g.alchemy.com/v2/YOUR_API_KEY
   ```

3. **Update Addresses**
   Before deploying, update the following addresses in `script/DeployPerpHook.s.sol`:
   - `POOLMANAGER`: Uniswap V4 PoolManager address on Sepolia (when available)
   - `USDC_SEPOLIA`: USDC token address on Sepolia
   - `ETH_USD_PRICE_FEED`: Chainlink ETH/USD price feed on Sepolia
   - Asset currency address (ETH/WETH) for your pool

## Deployment Steps

### 1. Mine Hook Address (Optional - for verification)

```bash
forge script script/DeployPerpHook.s.sol \
    --rpc-url $SEPOLIA_RPC_URL \
    --private-key $PRIVATE_KEY \
    --sig "run()" \
    --dry-run
```

This will show you the hook address that will be deployed without actually deploying.

### 2. Deploy the Hook

```bash
forge script script/DeployPerpHook.s.sol:DeployPerpHook \
    --rpc-url $SEPOLIA_RPC_URL \
    --private-key $PRIVATE_KEY \
    --broadcast \
    --verify \
    --etherscan-api-key YOUR_ETHERSCAN_API_KEY
```

### 3. Verify Deployment

After deployment, verify the hook:

```bash
forge script script/DeployPerpHook.s.sol:DeployPerpHook \
    --rpc-url $SEPOLIA_RPC_URL \
    --sig "verifyDeployment(address)" \
    HOOK_ADDRESS
```

## Post-Deployment Steps

1. **Set Price Feeds**
   - Call `setPriceFeed(assetCurrency, priceFeed)` for each asset you want to support
   - Example: Set ETH/USD price feed for ETH perpetuals

2. **Initialize Pool**
   - Create a pool using the deployed hook address
   - Pool key should include the hook address in the `hooks` field

3. **Add Liquidity**
   - Add initial liquidity to enable swaps

## Important Notes

- **Security**: In production, add access control to `setPriceFeed()` function
- **Price Feeds**: Ensure Chainlink price feeds are available for your asset pairs
- **Gas Costs**: Hook deployment and mining can be gas-intensive
- **Testing**: Test thoroughly on a local fork before deploying to Sepolia

## Chainlink Price Feed Addresses on Sepolia

Common price feeds on Sepolia:
- ETH/USD: `0x694AA1769357215DE4FAC081bf1f309aDC325306`
- BTC/USD: `0x1b44F3514812e835E1D0E15600A19C930c24B6fD`
- LINK/USD: `0xc59E3633BAAC79493d908e63626716e8A03ad498`

For more addresses, visit: https://docs.chain.link/data-feeds/price-feeds/addresses?network=ethereum&page=1#sepolia-testnet

## Troubleshooting

- **Address Mining Fails**: Increase `MAX_LOOP` in HookMiner or try different constructor args
- **Price Feed Not Found**: Verify Chainlink feed address is correct for Sepolia
- **Deployment Fails**: Ensure you have enough Sepolia ETH for gas fees

