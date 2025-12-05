# Swappy - Perpetual Exchange Hook for Uniswap V4

**Swappy** is a perpetual exchange hook for Uniswap V4 that enables leveraged trading with oracle-based pricing, inspired by GMX V2's architecture.

## Overview

Swappy transforms a Uniswap V4 pool into a perpetual exchange where:
- **Pricing** comes from Chainlink oracles (not the AMM curve)
- **Collateral** is managed through the pool's liquidity
- **Positions** are tracked per trader with margin requirements
- **Liquidation** is automated when positions become undercollateralized

### Key Features

- ✅ Oracle-based pricing (Chainlink) for manipulation-resistant mark prices
- ✅ Leveraged positions (up to 10x)
- ✅ Long and short positions
- ✅ Automatic margin checks and liquidations
- ✅ Trading fees (0.01% on position size)
- ✅ Real-time position tracking
- ✅ Flash accounting for efficient collateral movement

## Architecture

### How It Works

1. **Pricing**: The hook uses Chainlink price feeds to get mark prices, completely bypassing the AMM's internal pricing mechanism
2. **Collateral Management**: The Uniswap V4 pool acts as the collateral vault, using flash accounting to move funds efficiently
3. **Position Tracking**: Each trader's position (size, collateral, entry price) is stored on-chain
4. **Risk Management**: Margin requirements and liquidation checks happen automatically on every swap

### Core Components

- **`beforeSwap`**: Validates margin requirements, updates positions, calculates fees
- **`afterSwap`**: Handles liquidation checks, applies funding rates, settles PnL
- **Chainlink Integration**: Fetches mark prices from Chainlink price feeds
- **Position Storage**: Tracks all trader positions and total market skew

## Risk Parameters

| Parameter | Value | Description |
|-----------|-------|-------------|
| `INITIAL_MARGIN_RATE` | 10% | Minimum collateral required to open a position |
| `MAINTENANCE_MARGIN_RATE` | 5% | Minimum collateral to maintain a position (liquidation threshold) |
| `MAX_LEVERAGE` | 10x | Maximum leverage allowed |
| `FEE_PER_MILLION` | 0.01% | Trading fee charged on position size changes |

## Prerequisites

Before deploying, ensure you have:

1. **Foundry** installed:
   ```bash
   curl -L https://foundry.paradigm.xyz | bash
   foundryup
   ```

2. **Dependencies** installed:
   ```bash
   forge install
   ```

3. **Sepolia ETH** for gas fees (get from [Alchemy Faucet](https://www.alchemy.com/faucets/ethereum-sepolia) or [Infura Faucet](https://www.infura.io/faucet/sepolia))

4. **Environment variables** set up (see below)

## Deployment Guide

### Step 1: Environment Setup

Create a `.env` file in the project root:

```bash
# Your wallet private key (without 0x prefix)
PRIVATE_KEY=your_private_key_here

# Sepolia RPC URL (choose one)
SEPOLIA_RPC_URL=https://sepolia.infura.io/v3/YOUR_INFURA_KEY
# Or: https://eth-sepolia.g.alchemy.com/v2/YOUR_API_KEY

# Uniswap V4 PoolManager address on Sepolia
# Update this when Uniswap V4 is deployed to Sepolia
POOL_MANAGER_ADDRESS=0xE03A1074c86CFeDd5C142C4F04F1a1536e203543

# Etherscan API key for contract verification
ETHERSCAN_API_KEY=your_etherscan_api_key
```

### Step 2: Update Configuration

Before deploying, update addresses in `script/DeployPerpHook.s.sol`:

- **PoolManager**: Uniswap V4 PoolManager address on Sepolia
- **USDC_SEPOLIA**: USDC token address (collateral token)
- **WETH_SEPOLIA**: WETH address (asset token)
- **ETH_USD_PRICE_FEED**: Chainlink ETH/USD price feed address

**Sepolia Addresses:**
- Chainlink ETH/USD: `0x694AA1769357215DE4FAC081bf1f309aDC325306`
- WETH: `0x7b79995e5f793A07Bc00c21412e50Ecae098E7f9`
- USDC: `0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238`

### Step 3: Deploy the Hook

```bash
# Load environment variables
source .env

# Deploy PerpHook
forge script script/DeployPerpHook.s.sol:DeployPerpHook \
    --rpc-url $SEPOLIA_RPC_URL \
    --private-key $PRIVATE_KEY \
    --broadcast \
    --verify \
    --etherscan-api-key $ETHERSCAN_API_KEY \
    -vvvv
```

**Important**: Save the deployed hook address from the output!

### Step 4: Initialize Pool

After deployment, create a pool with your hook:

```bash
# Set the hook address from deployment
export HOOK_ADDRESS=<deployed_hook_address>
export ASSET_TOKEN=0x7b79995e5f793A07Bc00c21412e50Ecae098E7f9  # WETH
export COLLATERAL_TOKEN=0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238  # USDC

# Initialize the pool
forge script script/InitializePool.s.sol:InitializePool \
    --rpc-url $SEPOLIA_RPC_URL \
    --private-key $PRIVATE_KEY \
    --broadcast \
    -vvvv
```

### Step 5: Set Additional Price Feeds (Optional)

If you want to support more assets, set their price feeds:

```bash
cast send $HOOK_ADDRESS \
    "setPriceFeed(address,address)" \
    <ASSET_CURRENCY_ADDRESS> \
    <CHAINLINK_PRICE_FEED_ADDRESS> \
    --rpc-url $SEPOLIA_RPC_URL \
    --private-key $PRIVATE_KEY
```

## Usage

### Opening a Long Position

To open a long position, a trader deposits collateral and specifies a positive position size:

```solidity
// Encode hookData: (trader address, position size)
bytes memory hookData = abi.encode(traderAddress, int128(positionSize));

// Swap parameters
SwapParams({
    zeroForOne: false,  // Depositing collateral (token1 -> token0 direction)
    amountSpecified: -int256(collateralAmount),  // Negative = exact input
    sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
});

// Execute swap through PoolManager
poolManager.swap(poolKey, swapParams, hookData);
```

### Opening a Short Position

For a short position, use a negative position size:

```solidity
bytes memory hookData = abi.encode(traderAddress, -int128(positionSize));
// ... same swap parameters
```

### Closing a Position

To close a position, set position size to zero and withdraw collateral:

```solidity
bytes memory hookData = abi.encode(traderAddress, -int128(currentPositionSize));

SwapParams({
    zeroForOne: true,  // Withdrawing collateral
    amountSpecified: int256(collateralToWithdraw),  // Positive = exact output
    sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
});
```

## Development

### Build

```bash
forge build
```

### Test

```bash
# Run all tests
forge test

# Run with verbosity
forge test -vvv

# Run specific test
forge test --match-test test_openLongPosition
```

### Format

```bash
forge fmt
```

### Gas Snapshots

```bash
forge snapshot
```

## Testing

The test suite includes:

- ✅ Hook initialization and configuration
- ✅ Opening long/short positions
- ✅ Margin requirement validation
- ✅ Position increases/decreases
- ✅ Liquidation mechanics
- ✅ Multiple traders
- ✅ Price updates

Run tests:
```bash
forge test --match-contract PerpHookTest -vv
```

## How It Works (Technical Details)

### Swap Flow

1. **User initiates swap** → Calls `PoolManager.swap()` with `hookData` containing `(trader, positionSizeDelta)`

2. **`beforeSwap` hook executes**:
   - Fetches mark price from Chainlink oracle
   - Decodes trader address and position size delta from `hookData`
   - Calculates collateral delta from swap direction
   - Validates margin requirements
   - Updates position state
   - Calculates and deducts trading fees
   - Updates total market skew

3. **Standard AMM swap executes** (moves collateral via flash accounting)

4. **`afterSwap` hook executes**:
   - Checks for liquidation conditions
   - Applies funding rates (if implemented)
   - Returns settlement deltas

### Position Structure

```solidity
struct Position {
    int128 size;            // Position size (positive = long, negative = short)
    uint128 collateral;     // Collateral amount in base currency
    uint256 entryPrice;     // Mark price when position was opened/modified
    uint256 liquidationPrice; // Price threshold for liquidation
}
```

### Margin Calculation

Required collateral = `(Position Size × Mark Price × Initial Margin Rate) / 1,000,000`

Example: 5 ETH long at $2000 with 10% margin = `(5 × 2000 × 10,000) / 1,000,000 = 1,000 USDC`

## Security Considerations

⚠️ **Important Security Notes:**

1. **Access Control**: The `setPriceFeed()` function currently has **no access control**. Before mainnet:
   - Add `onlyOwner` modifier
   - Use a multi-sig or timelock contract
   - Consider OpenZeppelin's `Ownable` or `AccessControl`

2. **Price Feed Validation**:
   - Verify price feeds are legitimate Chainlink contracts
   - Stale price protection is implemented (1 hour threshold)
   - Consider adding circuit breakers for extreme price movements

3. **Testing**:
   - Test thoroughly on a local fork before mainnet
   - Use `anvil --fork $SEPOLIA_RPC_URL` to test locally
   - Run all tests: `forge test`

4. **Oracle Risk**:
   - Chainlink oracles can fail or be delayed
   - Consider implementing fallback oracles
   - Monitor for stale prices

## Architecture Diagram

```
┌─────────────────┐
│   Trader        │
└────────┬────────┘
         │
         │ swap(hookData: trader, sizeDelta)
         ▼
┌─────────────────┐
│  PoolManager    │
└────────┬────────┘
         │
         ├─► beforeSwap() ──► Get Chainlink Price
         │                    ├─► Validate Margin
         │                    ├─► Update Position
         │                    └─► Calculate Fees
         │
         ├─► Standard AMM Swap (moves collateral)
         │
         └─► afterSwap() ────► Check Liquidation
                              └─► Apply Funding
```

## Chainlink Price Feeds

The hook requires Chainlink price feeds for each asset you want to support. Common feeds on Sepolia:

| Asset Pair | Address |
|------------|---------|
| ETH/USD | `0x694AA1769357215DE4FAC081bf1f309aDC325306` |
| BTC/USD | `0x1b44F3514812e835E1D0E15600A19C930c24B6fD` |
| LINK/USD | `0xc59E3633BAAC79493d908e63626716e8A03ad498` |

For more addresses: [Chainlink Docs](https://docs.chainlink/data-feeds/price-feeds/addresses?network=ethereum&page=1#sepolia-testnet)

## Troubleshooting

### Address Mining Fails
- Increase `MAX_LOOP` in HookMiner (currently 160,444)
- Try different constructor arguments
- Use a different base currency address

### Price Feed Not Found
- Verify Chainlink feed address is correct for Sepolia
- Check feed exists: `cast call <FEED_ADDRESS> "latestRoundData()" --rpc-url $SEPOLIA_RPC_URL`

### Deployment Fails
- Ensure sufficient Sepolia ETH (recommend 0.1+ ETH)
- Check RPC URL: `cast block-number --rpc-url $SEPOLIA_RPC_URL`
- Verify private key is correct

### Pool Initialization Fails
- Verify hook address is correct
- Check token addresses are correct for Sepolia
- Ensure PoolManager is deployed and accessible

## Project Structure

```
swappy/
├── src/
│   ├── PerpHook.sol              # Main hook contract
│   └── interfaces/
│       └── IChainlinkPriceFeed.sol
├── script/
│   ├── DeployPerpHook.s.sol      # Deployment script
│   └── InitializePool.s.sol      # Pool initialization
├── test/
│   ├── PerpHook.t.sol            # Test suite
│   └── mocks/
│       └── MockOracle.sol        # Mock Chainlink feed
└── README.md                     # This file
```

## License

MIT

## Contributing

Contributions are welcome! Please ensure all tests pass before submitting PRs.

## Resources

- [Uniswap V4 Documentation](https://docs.uniswap.org/contracts/v4/overview)
- [Chainlink Price Feeds](https://docs.chainlink/data-feeds/price-feeds)
- [Foundry Book](https://book.getfoundry.sh/)
- [GMX V2 Documentation](https://docs.gmx.io/)

## Support

For issues or questions, please open an issue on GitHub.
