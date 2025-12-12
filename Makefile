# Include .env file if it exists (treated as Make variables)
-include .env

# Export commonly used vars so forge/anvil/scripts see them.
export MONAD_MAINNET_RPC_URL
export MONAD_TESTNET_RPC_URL
export GOV_PRIVATE_KEY
export ADDRESS_HUB
export FORK_BLOCK

# Network/RPC selection
NETWORK ?= monad-mainnet
FORK_BLOCK ?= latest

ifeq ($(NETWORK),monad-mainnet)
RPC_URL ?= $(MONAD_MAINNET_RPC_URL)
else ifeq ($(NETWORK),monad-testnet)
RPC_URL ?= $(MONAD_TESTNET_RPC_URL)
else
# Allow passing a raw RPC URL via NETWORK, or override RPC_URL directly.
RPC_URL ?= $(NETWORK)
endif

ifeq ($(FORK_BLOCK),latest)
FORK_BLOCK_FLAG =
else
FORK_BLOCK_FLAG = --fork-block-number $(FORK_BLOCK)
endif

.PHONY: all clean install build build-atlas format snapshot size test test-gas anvil fork-anvil deploy-atlas

# Default target
all: clean install build test

clean:
	forge clean

install:
	git submodule update --init --recursive
	forge install

build:
	forge build

build-atlas:
	forge build src/atlas/core/Atlas.sol src/atlas/core/AtlasVerification.sol src/atlas/helpers/Simulator.sol src/atlas/helpers/Sorter.sol --skip test --skip script

format:
	forge fmt

snapshot:
	forge snapshot

size:
	forge build --sizes

test:
	@if [ -z "$(MONAD_MAINNET_RPC_URL)" ]; then \
		echo "Error: MONAD_MAINNET_RPC_URL is not set. Put it in .env or export it."; \
		exit 1; \
	fi
	forge test -vvv

test-gas:
	@if [ -z "$(MONAD_MAINNET_RPC_URL)" ]; then \
		echo "Error: MONAD_MAINNET_RPC_URL is not set. Put it in .env or export it."; \
		exit 1; \
	fi
	forge test --gas-report -vvv

anvil:
	anvil

fork-anvil:
	@if [ -z "$(RPC_URL)" ]; then \
		echo "Error: RPC_URL not set. Set NETWORK=monad-mainnet or monad-testnet (and corresponding MONAD_*_RPC_URL in .env), or RPC_URL directly."; \
		exit 1; \
	fi
	anvil --fork-url $(RPC_URL) $(FORK_BLOCK_FLAG)

deploy-atlas:
	@if [ -z "$(GOV_PRIVATE_KEY)" ]; then \
		echo "Error: GOV_PRIVATE_KEY is not set."; \
		exit 1; \
	fi
	@if [ -z "$(RPC_URL)" ]; then \
		echo "Error: RPC_URL is not set. Set NETWORK or RPC_URL."; \
		exit 1; \
	fi
	forge script script/deploy-atlas.s.sol:DeployAtlasScript --rpc-url $(RPC_URL) --broadcast -vvv

