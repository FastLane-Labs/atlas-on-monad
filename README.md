# Atlas on Monad

This repository contains the Atlas V1 smart contracts adapted for the Monad ecosystem. Atlas is FastLane’s execution abstraction / application‑specific sequencing layer that lets each dApp define ordering and MEV rules.

- Core protocol contracts live in `src/atlas/**`.
- Shared common utilities live in `src/common/**`.
- Atlas integrates with ShMonad, which is pulled in from the `FastLane-Labs/fastlane-contracts` repo as a Foundry dependency.

## Documentation

- Source code: `src/atlas`
- Atlas docs: https://docs.shmonad.xyz/products/monad-atlas/overview/

## Development

### Prerequisites

- Foundry (forge/anvil)
- git with submodules enabled

### Setup

Fetch dependencies (including `lib/fastlane-contracts`):

```shell
git submodule update --init --recursive
```

### Build

```shell
forge build
```

### Tests (Monad mainnet fork)

Atlas tests fork Monad mainnet so they can talk to the live ShMonad proxy. The base test etches the mock Monad staking precompile from the dependency onto:

`0x0000000000000000000000000000000000001000`

1. Export a mainnet RPC URL:

```shell
export MONAD_MAINNET_RPC_URL=<your_rpc_url>
```

2. Run tests:

```shell
forge test -vvv

# Targeted example:
forge test \
  --match-path test/atlas/Sorter.t.sol \
  --match-test test_Sorter_sortBids_SingleValidSolver \
  -vvv
```

### Local node

```shell
anvil

# Or fork mainnet locally:
anvil --fork-url $MONAD_MAINNET_RPC_URL
```

## Deployment (Atlas)

An Atlas deployment script is available at `script/deploy-atlas.s.sol`. It is currently configured for Monad testnet addresses; update the ShMonad proxy address and policy ID when deploying to other networks.

```shell
forge script script/deploy-atlas.s.sol:DeployAtlasScript \
  --rpc-url <network_rpc_url> \
  --broadcast -vvv
```

## License

BUSL-1.1
