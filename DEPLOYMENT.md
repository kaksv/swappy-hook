# PerpHook Deployment Guide

## Quick Start

### 1. Setup Environment

```bash
# Create .env file
cat > .env << EOF
PRIVATE_KEY=your_private_key_without_0x
SEPOLIA_RPC_URL=https://sepolia.infura.io/v3/YOUR_KEY
POOL_MANAGER_ADDRESS=0xE03A1074c86CFeDd5C142C4F04F1a1536e203543
ETHERSCAN_API_KEY=your_etherscan_key
EOF
```

### 2. Deploy Hook

```bash
source .env
forge script script/DeployPerpHook.s.sol:DeployPerpHook \
    --rpc-url $SEPOLIA_RPC_URL \
    --private-key $PRIVATE_KEY \
    --broadcast \
    --verify \
    --etherscan-api-key $ETHERSCAN_API_KEY \
    -vvvv
```

### 3. Initialize Pool

```bash
# Set hook address from deployment output
export HOOK_ADDRESS=<deployed_address>
export ASSET_TOKEN=0x7b79995e5f793A07Bc00c21412e50Ecae098E7f9  # WETH
export COLLATERAL_TOKEN=0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238  # USDC

forge script script/InitializePool.s.sol:InitializePool \
    --rpc-url $SEPOLIA_RPC_URL \
    --private-key $PRIVATE_KEY \
    --broadcast \
    -vvvv
```

## Files Created

- `script/DeployPerpHook.s.sol` - Main deployment script
- `script/InitializePool.s.sol` - Pool initialization script  
- `script/README_DEPLOYMENT.md` - Detailed deployment guide

## Important Addresses (Sepolia)

- **Chainlink ETH/USD**: `0x694AA1769357215DE4FAC081bf1f309aDC325306`
- **WETH**: `0x7b79995e5f793A07Bc00c21412e50Ecae098E7f9`
- **USDC**: `0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238`

