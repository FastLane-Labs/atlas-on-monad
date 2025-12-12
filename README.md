# Fastlane Contracts

Smart contracts powering Fastlane-Labs' infrastructure on Monad.

## About FastLane Labs

Fastlane-Labs is building critical infrastructure for the Monad ecosystem, focusing on improving the developer and user experience through optimized smart contracts and services.

## Projects

### Atlas

Atlas is FastLane's application-specific sequencing layer, letting each dApp set its own rules for transaction ordering and MEV handling. It captures the surrounding MEV and leaves distribution up to the application—whether that means rebating users, rewarding LPs, or powering protocol revenue.

[Source Code](./src/atlas) | [Documentation](https://docs.shmonad.xyz/products/monad-atlas/overview/)

### Shmonad

Stake MON, get shMON—the liquid staking token that keeps earning + MEV rewards while you commit it into policy "vaults." One token secures the network and backs your favourite dApps, all without sacrificing liquidity.

[Source Code](./src/shmonad) | [Documentation](https://docs.shmonad.xyz/products/shmonad/overview/)

### Task Manager

An on-chain "cron" that lets anyone schedule a transaction for a future block and guarantees it executes, paid for with bonded shMON or MON. No off-chain bots, no forgotten claims—just a single call to set it and forget it.

[Source Code](./src/task-manager) | [Documentation](https://docs.shmonad.xyz/products/task-manager/overview/)

### Paymaster

A ready-made ERC-4337 bundler that batches UserOps and fronts gas via a shMON-funded Paymaster. The bundler handles Monad's async quirks and gets your transactions on-chain.

[Source Code](./src/paymaster) | [Documentation](https://docs.shmonad.xyz/products/shbundler-4337/paymaster/)

### Gas Relay

A module that enables seamless gas-less UX for dApps, powered by ShMonad and the Atlas Task Manager. Users sign with their regular wallet once, then interact through an expendable session key while the dApp silently handles gas payments.

Key features:
- No user gas pop-ups - improves onboarding and reduces drop-off
- Policy-driven security with ShMonad commitment policies
- Composable with Atlas MEV framework and EVM-compatible contracts

[Source Code](./src/common/relay) | [Module Documentation](./src/common/relay/README.md)

## Development

### Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation)
- Make

### Quick Start

```shell
# Install dependencies
$ make install

# Build the project
$ make build

# Run tests
$ make test
```

### Available Commands

```shell
# Clean, install dependencies, build and test
$ make all

# Run tests with gas reporting
$ make test-gas

# Format code
$ make format

# Generate gas snapshots
$ make snapshot

# Run ShMonad scenario suite (set SIM_VALIDATOR_ASSERTS=false to bypass validator-only checks)
$ make simulation-local

# Start local node
$ make anvil

# Fork a specific network for testing
$ make fork-anvil NETWORK=monad-testnet

# Check contract sizes
$ make size
```

### ShMonad scenario suite

- Complex scenario tests in `test/shmonad/scenarios/ComplexScenarios.t.sol` now snapshot global accounting state via `TestShMonad` before and after each action (deposits, boosts, withdraws) to keep coverage focused on ledger consistency rather than per-validator splits.
- Validator-specific assertions remain available for regression coverage but can be disabled by setting `SIMULATION_VALIDATOR_ASSERTS=false` (for example: `make simulation-local SIM_VALIDATOR_ASSERTS=false`).

### Deployment

To deploy contracts:

1. Set environment variables:
```shell
NETWORK=<your_rpc_url>
GOV_PRIVATE_KEY=<your_private_key>
ADDRESS_HUB=<address_hub_address> # for subsequent deployments
```

2. Run specific deployment targets:
```shell
# Deploy individual components
$ make deploy-address-hub
$ make deploy-atlas
$ make deploy-shmonad
$ make deploy-taskmanager
$ make deploy-paymaster
```

### Contract Verification

Generate verification JSON files for contract verification on block explorers:

```shell
# Generate verification JSON for a contract
$ make generate-verification-json \
    CONTRACT_ADDRESS=0x123... \
    CONTRACT_PATH=src/MyContract.sol:MyContract

# With constructor arguments
$ make generate-verification-json \
    CONTRACT_ADDRESS=0x123... \
    CONTRACT_PATH=src/MyContract.sol:MyContract \
    CONSTRUCTOR_ARGS=0x456...
```

**Examples:**
```shell
# Atlas contract
$ make generate-verification-json \
    CONTRACT_ADDRESS=0x4a730A56344873FB28f7C3d65A67Fea56f5e0F46 \
    CONTRACT_PATH=src/atlas/core/Atlas.sol:Atlas \
    CONSTRUCTOR_ARGS=0x00000000000000000000000000000000000000000000000000000000000009c4...

# AtlasVerification contract  
$ make generate-verification-json \
    CONTRACT_ADDRESS=0x834B181d1F4Cd9Ec61E02D0DF0E5e4F944eFA508 \
    CONTRACT_PATH=src/atlas/core/AtlasVerification.sol:AtlasVerification \
    CONSTRUCTOR_ARGS=0x0000000000000000000000004a730a56344873fb28f7c3d65a67fea56f5e0f46...
```

Generated JSON files are saved to `cache/etherscan_ContractName_timestamp.json` and can be:
- Uploaded manually to block explorer verification pages
- Used for API-based verification when available
- Referenced for compilation settings and source code

## Documentation

For full documentation, visit [docs.shmonad.xyz](https://docs.shmonad.xyz/).
