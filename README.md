## Swappy


**Swappy is a Perpetual exchange hook Inspired by GMX**
What we are going to use:
We are to use GMX V2's approach for Liquidity Pools as counterparty and oracle-based pricing rather than using CLOBs of hyperliquid and paradex.
This makes it easy to integrate more naturally into the AMM structure.

The hook will esentially override the standard AMM pricing with an oracle-based "mark price" and the pool will be used for collateral management.

### Core Logic
` _PerpHook_ ` is to have logic in the `beforeSwap` and `afterSwap` function to manage leveraged position



**Foundry is a blazing fast, portable and modular toolkit for Ethereum application development written in Rust.**

Foundry consists of:

-   **Forge**: Ethereum testing framework (like Truffle, Hardhat and DappTools).
-   **Cast**: Swiss army knife for interacting with EVM smart contracts, sending transactions and getting chain data.
-   **Anvil**: Local Ethereum node, akin to Ganache, Hardhat Network.
-   **Chisel**: Fast, utilitarian, and verbose solidity REPL.

## Documentation

https://book.getfoundry.sh/

## Usage

### Build

```shell
$ forge build
```

### Test

```shell
$ forge test
```

### Format

```shell
$ forge fmt
```

### Gas Snapshots

```shell
$ forge snapshot
```

### Anvil

```shell
$ anvil
```

### Deploy

```shell
$ forge script script/Counter.s.sol:CounterScript --rpc-url <your_rpc_url> --private-key <your_private_key>
```

### Cast

```shell
$ cast <subcommand>
```

### Help

```shell
$ forge --help
$ anvil --help
$ cast --help
```
