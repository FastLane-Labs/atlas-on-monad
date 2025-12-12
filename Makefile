# Include .env file if it exists
-include .env

# Include test-specific Makefile
include test/Makefile

# Default network and RPC settings
NETWORK ?= monad-testnet
# Extract network type and name from NETWORK variable (e.g., eth-mainnet -> ETH_MAINNET)
NETWORK_UPPER = $(shell echo $(NETWORK) | tr 'a-z-' 'A-Z_')
# Override any existing RPC_URL with the network-specific one
RPC_URL = $($(NETWORK_UPPER)_RPC_URL)
# Default fork block (can be overridden)
FORK_BLOCK ?= latest

# Conditionally set the fork block number flag
ifeq ($(FORK_BLOCK),latest)
  FORK_BLOCK_FLAG = 
else
  FORK_BLOCK_FLAG = --fork-block-number $(FORK_BLOCK)
endif

# Debug target
debug-network:
	@echo "NETWORK: $(NETWORK)"
	@echo "NETWORK_UPPER: $(NETWORK_UPPER)"
	@echo "RPC_URL: $(RPC_URL)"
	@echo "FORK_BLOCK: $(FORK_BLOCK)"
	@echo "FORK_BLOCK_FLAG: $(FORK_BLOCK_FLAG)"

# Declare all PHONY targets (test targets are declared in test/Makefile)
.PHONY: all clean install build format snapshot anvil size update
.PHONY: deploy test-deploy fork-anvil fork-test-deploy
.PHONY: deploy-address-hub deploy-shmonad deploy-taskmanager deploy-paymaster deploy-sponsored-executor
.PHONY: upgrade-address-hub upgrade-shmonad upgrade-taskmanager upgrade-paymaster deploy-shmonad-implementation
.PHONY: test-deploy-address-hub test-deploy-shmonad test-deploy-taskmanager test-deploy-paymaster test-deploy-sponsored-executor
.PHONY: test-upgrade-address-hub test-upgrade-shmonad test-upgrade-taskmanager test-upgrade-paymaster
.PHONY: fork-test-deploy-address-hub fork-test-deploy-shmonad fork-test-deploy-taskmanager fork-test-deploy-paymaster fork-test-deploy-sponsored-executor
.PHONY: fork-test-upgrade-address-hub fork-test-upgrade-shmonad fork-test-upgrade-taskmanager fork-test-upgrade-paymaster
.PHONY: request-tokens get-paymaster-info scenario_test_upgrade replay-tx generate-verification-json
.PHONY: deploy-timelock test-deploy-timelock test-transfer-to-timelock test-schedule-timelock-upgrade test-execute-timelock-upgrade

# Default target
all: clean install build test

# Build and test targets
clean:
	forge clean

install:
	forge install

build:
	forge build

build-shmonad:
	forge build src/shmonad/ShMonad.sol --skip test --skip script

build-atlas:
	forge build \
  	src/atlas/core/Atlas.sol \
  	src/atlas/core/AtlasVerification.sol \
  	src/atlas/helpers/Simulator.sol \
  	src/atlas/helpers/Sorter.sol \
  	--skip test --skip script

# Note: All test targets are defined in test/Makefile

format:
	forge fmt

snapshot:
	forge snapshot

anvil:
	anvil

# Start anvil with fork of the specified network
fork-anvil: debug-network
	@if [ -z "$(RPC_URL)" ]; then echo "No RPC URL found for network $(NETWORK)"; exit 1; fi
	@echo "Starting anvil with fork of $(NETWORK) at block $(FORK_BLOCK)..."
	anvil --fork-url $(RPC_URL) $(FORK_BLOCK_FLAG)

size:
	forge build --sizes

update:
	forge update 

# Get paymaster info
get-paymaster-info: debug-network
	@if [ -z "$(ADDRESS_HUB)" ]; then echo "ADDRESS_HUB is not set"; exit 1; fi
	@if [ -z "$(RPC_URL)" ]; then echo "No RPC URL found for network $(NETWORK)"; exit 1; fi
	@echo "Getting Paymaster info on $(NETWORK)..."
	forge script script/utils/getPaymasterInfo.s.sol:GetPaymasterInfoScript \
		--rpc-url $(RPC_URL) \
		-vvv

# Faucet interaction
request-tokens: debug-network
	@if [ -z "$(GOV_PRIVATE_KEY)" ]; then echo "GOV_PRIVATE_KEY is not set"; exit 1; fi
	@if [ -z "$(RPC_URL)" ]; then echo "No RPC URL found for network $(NETWORK)"; exit 1; fi
	@echo "Requesting tokens from faucet on $(NETWORK)..."
	forge script script/faucet/RequestTokens.s.sol:RequestTokensScript \
		--rpc-url $(RPC_URL) \
		--broadcast \
		-vvv

# Deployment test targets (without forking)
test-deploy-address-hub: debug-network
	@if [ -z "$(GOV_PRIVATE_KEY)" ]; then echo "GOV_PRIVATE_KEY is not set"; exit 1; fi
	@if [ -z "$(RPC_URL)" ]; then echo "No RPC URL found for network $(NETWORK)"; exit 1; fi
	@echo "Testing AddressHub deployment on $(NETWORK)..."
	forge script script/deploy-address-hub.s.sol:DeployAddressHubScript \
		--rpc-url $(RPC_URL) \
		-vvvv

test-upgrade-address-hub: debug-network
	@if [ -z "$(GOV_PRIVATE_KEY)" ]; then echo "GOV_PRIVATE_KEY is not set"; exit 1; fi
	@if [ -z "$(ADDRESS_HUB)" ]; then echo "ADDRESS_HUB is not set"; exit 1; fi
	@if [ -z "$(RPC_URL)" ]; then echo "No RPC URL found for network $(NETWORK)"; exit 1; fi
	@echo "Testing AddressHub upgrade on $(NETWORK)..."
	forge script script/upgrade-address-hub.s.sol:UpgradeAddressHubScript \
		--rpc-url $(RPC_URL) \
		-vvvv

test-deploy-atlas:
	@if [ -z "$(GOV_PRIVATE_KEY)" ]; then echo "GOV_PRIVATE_KEY is not set"; exit 1; fi
	@if [ -z "$(RPC_URL)" ]; then echo "No RPC URL found for network $(NETWORK)"; exit 1; fi
	@echo "Testing Atlas deployment on $(NETWORK)..."
	forge script script/deploy-atlas.s.sol:DeployAtlasScript \
		--rpc-url $(RPC_URL) \
		-vvv

test-deploy-shmonad:
	@if [ -z "$(GOV_PRIVATE_KEY)" ]; then echo "GOV_PRIVATE_KEY is not set"; exit 1; fi
	@if [ -z "$(ADDRESS_HUB)" ]; then echo "ADDRESS_HUB is not set"; exit 1; fi
	@if [ -z "$(RPC_URL)" ]; then echo "No RPC URL found for network $(NETWORK)"; exit 1; fi
	@echo "Testing shMONAD deployment on $(NETWORK)..."
	DEPLOY_WHAT=shmonad DEPLOY_PROXY_SHMONAD=true forge script script/deploy-proxies.s.sol:DeployProxiesScript \
		--rpc-url $(RPC_URL) \
		-vvv

test-upgrade-shmonad:
	@if [ -z "$(GOV_PRIVATE_KEY)" ]; then echo "GOV_PRIVATE_KEY is not set"; exit 1; fi
	@if [ -z "$(ADDRESS_HUB)" ]; then echo "ADDRESS_HUB is not set"; exit 1; fi
	@if [ -z "$(RPC_URL)" ]; then echo "No RPC URL found for network $(NETWORK)"; exit 1; fi
	@echo "Testing shMONAD upgrade on $(NETWORK)..."
	forge script script/upgrade-shmonad.s.sol:UpgradeShMonadScript \
		--rpc-url $(RPC_URL) \
		-vvv

test-deploy-taskmanager:
	@if [ -z "$(GOV_PRIVATE_KEY)" ]; then echo "GOV_PRIVATE_KEY is not set"; exit 1; fi
	@if [ -z "$(ADDRESS_HUB)" ]; then echo "ADDRESS_HUB is not set"; exit 1; fi
	@if [ -z "$(RPC_URL)" ]; then echo "No RPC URL found for network $(NETWORK)"; exit 1; fi
	@echo "Testing TaskManager deployment on $(NETWORK)..."
	DEPLOY_WHAT=taskmanager DEPLOY_PROXY_TASK_MANAGER=true forge script script/deploy-proxies.s.sol:DeployProxiesScript \
		--rpc-url $(RPC_URL) \
		-vvv

test-upgrade-taskmanager: debug-network
	@if [ -z "$(GOV_PRIVATE_KEY)" ]; then echo "GOV_PRIVATE_KEY is not set"; exit 1; fi
	@if [ -z "$(ADDRESS_HUB)" ]; then echo "ADDRESS_HUB is not set"; exit 1; fi
	@if [ -z "$(RPC_URL)" ]; then echo "No RPC URL found for network $(NETWORK)"; exit 1; fi
	@echo "Testing TaskManager upgrade on $(NETWORK)..."
	forge script script/upgrade-task-manager.s.sol:UpgradeTaskManagerScript \
		--rpc-url $(RPC_URL) \
		-vvv

test-deploy-paymaster:
	@if [ -z "$(GOV_PRIVATE_KEY)" ]; then echo "GOV_PRIVATE_KEY is not set"; exit 1; fi
	@if [ -z "$(ADDRESS_HUB)" ]; then echo "ADDRESS_HUB is not set"; exit 1; fi
	@if [ -z "$(RPC_URL)" ]; then echo "No RPC URL found for network $(NETWORK)"; exit 1; fi
	@echo "Testing Paymaster deployment on $(NETWORK)..."
	DEPLOY_WHAT=paymaster DEPLOY_PROXY_PAYMASTER=true forge script script/deploy-proxies.s.sol:DeployProxiesScript \
		--rpc-url $(RPC_URL) \
		-vvv

test-upgrade-paymaster: debug-network
	@if [ -z "$(GOV_PRIVATE_KEY)" ]; then echo "GOV_PRIVATE_KEY is not set"; exit 1; fi
	@if [ -z "$(ADDRESS_HUB)" ]; then echo "ADDRESS_HUB is not set"; exit 1; fi
	@if [ -z "$(RPC_URL)" ]; then echo "No RPC URL found for network $(NETWORK)"; exit 1; fi
	@echo "Testing Paymaster upgrade on $(NETWORK)..."
	forge script script/upgrade-paymaster.s.sol:UpgradePaymasterScript \
		--rpc-url $(RPC_URL) \
		-vvv

# Add the test-deploy-sponsored-executor target
test-deploy-sponsored-executor:
	@if [ -z "$(GOV_PRIVATE_KEY)" ]; then echo "GOV_PRIVATE_KEY is not set"; exit 1; fi
	@if [ -z "$(ADDRESS_HUB)" ]; then echo "ADDRESS_HUB is not set"; exit 1; fi
	@echo "Testing SponsoredExecutor deployment on $(NETWORK)..."
	forge script script/deploy-sponsored-executor.s.sol:DeploySponsoredExecutorScript \
		--rpc-url $(RPC_URL) \
		-vvv

# Timelock governance targets (generic - works with any proxy)

test-deploy-timelock:
	@if [ -z "$(TIMELOCK_OWNER_PK)" ]; then echo "TIMELOCK_OWNER_PK is not set"; exit 1; fi
	@if [ -z "$(RPC_URL)" ]; then echo "No RPC URL found for network $(NETWORK)"; exit 1; fi
	@echo "Testing TimelockController deployment on $(NETWORK)..."
	forge script script/timelock/deploy-timelock.s.sol:DeployTimelockScript \
		--rpc-url $(RPC_URL) \
		-vvv

deploy-timelock:
	@if [ -z "$(TIMELOCK_OWNER_PK)" ]; then echo "TIMELOCK_OWNER_PK is not set"; exit 1; fi
	@if [ -z "$(RPC_URL)" ]; then echo "No RPC URL found for network $(NETWORK)"; exit 1; fi
	@echo "Deploying TimelockController on $(NETWORK)..."
	forge script script/timelock/deploy-timelock.s.sol:DeployTimelockScript \
		--rpc-url $(RPC_URL) \
		--broadcast \
		--verify \
		-vvv

test-transfer-to-timelock:
	@if [ -z "$(PROXY_ADMIN_OWNER_PK)" ]; then echo "PROXY_ADMIN_OWNER_PK is not set"; exit 1; fi
	@if [ -z "$(PROXY_ADMIN_ADDRESS)" ]; then echo "PROXY_ADMIN_ADDRESS is not set"; exit 1; fi
	@if [ -z "$(TIMELOCK_ADDRESS)" ]; then echo "TIMELOCK_ADDRESS is not set"; exit 1; fi
	@if [ -z "$(RPC_URL)" ]; then echo "No RPC URL found for network $(NETWORK)"; exit 1; fi
	@echo "Testing transfer ownership to timelock on $(NETWORK)..."
	forge script script/timelock/transfer-ownership-to-timelock.s.sol:TransferOwnershipToTimelockScript \
		--rpc-url $(RPC_URL) \
		-vvv

test-schedule-timelock-upgrade:
	@if [ -z "$(TIMELOCK_OWNER_PK)" ]; then echo "TIMELOCK_OWNER_PK is not set"; exit 1; fi
	@if [ -z "$(PROXY_ADDRESS)" ]; then echo "PROXY_ADDRESS is not set"; exit 1; fi
	@if [ -z "$(PROXY_ADMIN_ADDRESS)" ]; then echo "PROXY_ADMIN_ADDRESS is not set"; exit 1; fi
	@if [ -z "$(TIMELOCK_ADDRESS)" ]; then echo "TIMELOCK_ADDRESS is not set"; exit 1; fi
	@if [ -z "$(NEW_IMPLEMENTATION_ADDRESS)" ]; then echo "NEW_IMPLEMENTATION_ADDRESS is not set"; exit 1; fi
	@if [ -z "$(RPC_URL)" ]; then echo "No RPC URL found for network $(NETWORK)"; exit 1; fi
	@echo "Testing schedule upgrade through timelock on $(NETWORK)..."
	forge script script/timelock/schedule-upgrade-through-timelock.s.sol:ScheduleUpgradeThroughTimelockScript \
		--rpc-url $(RPC_URL) \
		-vvv

test-execute-timelock-upgrade:
	@if [ -z "$(TIMELOCK_OWNER_PK)" ]; then echo "TIMELOCK_OWNER_PK is not set"; exit 1; fi
	@if [ -z "$(PROXY_ADDRESS)" ]; then echo "PROXY_ADDRESS is not set"; exit 1; fi
	@if [ -z "$(PROXY_ADMIN_ADDRESS)" ]; then echo "PROXY_ADMIN_ADDRESS is not set"; exit 1; fi
	@if [ -z "$(TIMELOCK_ADDRESS)" ]; then echo "TIMELOCK_ADDRESS is not set"; exit 1; fi
	@if [ -z "$(NEW_IMPLEMENTATION_ADDRESS)" ]; then echo "NEW_IMPLEMENTATION_ADDRESS is not set"; exit 1; fi
	@if [ -z "$(OPERATION_ID)" ]; then echo "OPERATION_ID is not set"; exit 1; fi
	@if [ -z "$(SALT)" ]; then echo "SALT is not set"; exit 1; fi
	@if [ -z "$(RPC_URL)" ]; then echo "No RPC URL found for network $(NETWORK)"; exit 1; fi
	@echo "Testing execute timelock upgrade on $(NETWORK)..."
	forge script script/timelock/execute-timelock-upgrade.s.sol:ExecuteTimelockUpgradeScript \
		--rpc-url $(RPC_URL) \
		-vvv

fork-test-upgrade: fork-test-upgrade-address-hub fork-test-upgrade-shmonad fork-test-upgrade-taskmanager fork-test-upgrade-paymaster
	@echo "All fork-based upgrade tests completed for $(NETWORK)"

# Deployment targets
deploy-address-hub:
	@if [ -z "$(GOV_PRIVATE_KEY)" ]; then echo "GOV_PRIVATE_KEY is not set"; exit 1; fi
	@if [ -z "$(RPC_URL)" ]; then echo "No RPC URL found for network $(NETWORK)"; exit 1; fi
	@echo "Deploying AddressHub to $(NETWORK)..."
	forge script script/deploy-address-hub.s.sol:DeployAddressHubScript \
		--rpc-url $(RPC_URL) \
		--broadcast \
		-vvv

deploy-atlas:
	@if [ -z "$(GOV_PRIVATE_KEY)" ]; then echo "GOV_PRIVATE_KEY is not set"; exit 1; fi
	@if [ -z "$(RPC_URL)" ]; then echo "No RPC URL found for network $(NETWORK)"; exit 1; fi
	@echo "Deploying Atlas to $(NETWORK)..."
	forge script script/deploy-atlas.s.sol:DeployAtlasScript \
		--rpc-url $(RPC_URL) \
		--broadcast \
		-vvv

deploy-shmonad:
	@if [ -z "$(GOV_PRIVATE_KEY)" ]; then echo "GOV_PRIVATE_KEY is not set"; exit 1; fi
	@if [ -z "$(ADDRESS_HUB)" ]; then echo "ADDRESS_HUB is not set"; exit 1; fi
	@if [ -z "$(RPC_URL)" ]; then echo "No RPC URL found for network $(NETWORK)"; exit 1; fi
	@echo "Deploying shMONAD to $(NETWORK)..."
	DEPLOY_WHAT=shmonad DEPLOY_PROXY_SHMONAD=true forge script script/deploy-proxies.s.sol:DeployProxiesScript \
		--rpc-url $(RPC_URL) \
		--broadcast \
		-vvv
	
upgrade-shmonad:
	@if [ -z "$(GOV_PRIVATE_KEY)" ]; then echo "GOV_PRIVATE_KEY is not set"; exit 1; fi
	@if [ -z "$(ADDRESS_HUB)" ]; then echo "ADDRESS_HUB is not set"; exit 1; fi
	@if [ -z "$(RPC_URL)" ]; then echo "No RPC URL found for network $(NETWORK)"; exit 1; fi
	@echo "Upgrading shMONAD on $(NETWORK)..."
	forge script script/upgrade-shmonad.s.sol:UpgradeShMonadScript \
		--rpc-url $(RPC_URL) \
		--broadcast \
		-vvv

deploy-shmonad-implementation:
	@if [ -z "$(GOV_PRIVATE_KEY)" ]; then echo "GOV_PRIVATE_KEY is not set"; exit 1; fi
	@if [ -z "$(ADDRESS_HUB)" ]; then echo "ADDRESS_HUB is not set"; exit 1; fi
	@if [ -z "$(RPC_URL)" ]; then echo "No RPC URL found for network $(NETWORK)"; exit 1; fi
	@echo "Deploying shMONAD implementation only on $(NETWORK)..."
	@echo "This will NOT upgrade the proxy - use with timelock governance"
	forge script script/deploy-shmonad-implementation.s.sol:DeployShMonadImplementationScript \
		--rpc-url $(RPC_URL) \
		--broadcast \
		-vvv

deploy-taskmanager:
	@if [ -z "$(GOV_PRIVATE_KEY)" ]; then echo "GOV_PRIVATE_KEY is not set"; exit 1; fi
	@if [ -z "$(ADDRESS_HUB)" ]; then echo "ADDRESS_HUB is not set"; exit 1; fi
	@if [ -z "$(PAYOUT_ADDRESS)" ]; then echo "PAYOUT_ADDRESS is not set"; exit 1; fi
	@if [ -z "$(RPC_URL)" ]; then echo "No RPC URL found for network $(NETWORK)"; exit 1; fi
	@echo "Deploying TaskManager to $(NETWORK)..."
	DEPLOY_WHAT=taskmanager DEPLOY_PROXY_TASK_MANAGER=true forge script script/deploy-proxies.s.sol:DeployProxiesScript \
		--rpc-url $(RPC_URL) \
		--broadcast \
		-vvv

upgrade-taskmanager:
	@if [ -z "$(GOV_PRIVATE_KEY)" ]; then echo "GOV_PRIVATE_KEY is not set"; exit 1; fi
	@if [ -z "$(ADDRESS_HUB)" ]; then echo "ADDRESS_HUB is not set"; exit 1; fi
	@if [ -z "$(RPC_URL)" ]; then echo "No RPC URL found for network $(NETWORK)"; exit 1; fi
	@echo "Upgrading TaskManager on $(NETWORK)..."
	forge script script/upgrade-task-manager.s.sol:UpgradeTaskManagerScript \
		--rpc-url $(RPC_URL) \
		--broadcast \
		-vvv

deploy-paymaster:
	@if [ -z "$(GOV_PRIVATE_KEY)" ]; then echo "GOV_PRIVATE_KEY is not set"; exit 1; fi
	@if [ -z "$(ADDRESS_HUB)" ]; then echo "ADDRESS_HUB is not set"; exit 1; fi
	@if [ -z "$(RPC_URL)" ]; then echo "No RPC URL found for network $(NETWORK)"; exit 1; fi
	@echo "Deploying Paymaster to $(NETWORK)..."
	DEPLOY_WHAT=paymaster DEPLOY_PROXY_PAYMASTER=true forge script script/deploy-proxies.s.sol:DeployProxiesScript \
		--rpc-url $(RPC_URL) \
		--broadcast \
		-vvv

upgrade-paymaster:
	@if [ -z "$(GOV_PRIVATE_KEY)" ]; then echo "GOV_PRIVATE_KEY is not set"; exit 1; fi
	@if [ -z "$(ADDRESS_HUB)" ]; then echo "ADDRESS_HUB is not set"; exit 1; fi
	@if [ -z "$(RPC_URL)" ]; then echo "No RPC URL found for network $(NETWORK)"; exit 1; fi
	@echo "Upgrading Paymaster on $(NETWORK)..."
	forge script script/upgrade-paymaster.s.sol:UpgradePaymasterScript \
		--rpc-url $(RPC_URL) \
		--broadcast \
		-vvv

# Add the deploy-sponsored-executor target
deploy-sponsored-executor:
	@if [ -z "$(GOV_PRIVATE_KEY)" ]; then echo "GOV_PRIVATE_KEY is not set"; exit 1; fi
	@if [ -z "$(ADDRESS_HUB)" ]; then echo "ADDRESS_HUB is not set"; exit 1; fi
	@echo "Deploying SponsoredExecutor on $(NETWORK)..."
	forge script script/deploy-sponsored-executor.s.sol:DeploySponsoredExecutorScript \
		--rpc-url $(RPC_URL) \
		--broadcast \
		--verify \
		-vvv

# Transfer ownership to timelock targets
transfer-ownership-to-timelock:
	@if [ -z "$(PROXY_ADMIN_OWNER_PK)" ]; then echo "PROXY_ADMIN_OWNER_PK is not set"; exit 1; fi
	@if [ -z "$(PROXY_ADMIN_ADDRESS)" ]; then echo "PROXY_ADMIN_ADDRESS is not set"; exit 1; fi
	@if [ -z "$(TIMELOCK_ADDRESS)" ]; then echo "TIMELOCK_ADDRESS is not set"; exit 1; fi
	@if [ -z "$(RPC_URL)" ]; then echo "No RPC URL found for network $(NETWORK)"; exit 1; fi
	@echo "Transferring ownership to timelock on $(NETWORK)..."
	forge script script/timelock/transfer-ownership-to-timelock.s.sol:TransferOwnershipToTimelockScript \
		--rpc-url $(RPC_URL) \
		--broadcast \
		-vvv

# Schedule upgrade through timelock
schedule-timelock-upgrade:
	@if [ -z "$(TIMELOCK_OWNER_PK)" ]; then echo "TIMELOCK_OWNER_PK is not set"; exit 1; fi
	@if [ -z "$(PROXY_ADDRESS)" ]; then echo "PROXY_ADDRESS is not set"; exit 1; fi
	@if [ -z "$(PROXY_ADMIN_ADDRESS)" ]; then echo "PROXY_ADMIN_ADDRESS is not set"; exit 1; fi
	@if [ -z "$(TIMELOCK_ADDRESS)" ]; then echo "TIMELOCK_ADDRESS is not set"; exit 1; fi
	@if [ -z "$(NEW_IMPLEMENTATION_ADDRESS)" ]; then echo "NEW_IMPLEMENTATION_ADDRESS is not set"; exit 1; fi
	@if [ -z "$(RPC_URL)" ]; then echo "No RPC URL found for network $(NETWORK)"; exit 1; fi
	@echo "Scheduling upgrade through timelock on $(NETWORK)..."
	forge script script/timelock/schedule-upgrade-through-timelock.s.sol:ScheduleUpgradeThroughTimelockScript \
		--rpc-url $(RPC_URL) \
		--broadcast \
		-vvv

# Execute scheduled upgrade
execute-timelock-upgrade:
	@if [ -z "$(TIMELOCK_OWNER_PK)" ]; then echo "TIMELOCK_OWNER_PK is not set"; exit 1; fi
	@if [ -z "$(PROXY_ADDRESS)" ]; then echo "PROXY_ADDRESS is not set"; exit 1; fi
	@if [ -z "$(PROXY_ADMIN_ADDRESS)" ]; then echo "PROXY_ADMIN_ADDRESS is not set"; exit 1; fi
	@if [ -z "$(TIMELOCK_ADDRESS)" ]; then echo "TIMELOCK_ADDRESS is not set"; exit 1; fi
	@if [ -z "$(NEW_IMPLEMENTATION_ADDRESS)" ]; then echo "NEW_IMPLEMENTATION_ADDRESS is not set"; exit 1; fi
	@if [ -z "$(OPERATION_ID)" ]; then echo "OPERATION_ID is not set"; exit 1; fi
	@if [ -z "$(SALT)" ]; then echo "SALT is not set"; exit 1; fi
	@if [ -z "$(RPC_URL)" ]; then echo "No RPC URL found for network $(NETWORK)"; exit 1; fi
	@echo "Executing timelock upgrade on $(NETWORK)..."
	forge script script/timelock/execute-timelock-upgrade.s.sol:ExecuteTimelockUpgradeScript \
		--rpc-url $(RPC_URL) \
		--broadcast \
		-vvv

# Add RPC Policy deployment targets
test-deploy-rpcpolicy:
	@if [ -z "$(GOV_PRIVATE_KEY)" ]; then echo "GOV_PRIVATE_KEY is not set"; exit 1; fi
	@if [ -z "$(ADDRESS_HUB)" ]; then echo "ADDRESS_HUB is not set"; exit 1; fi
	@if [ -z "$(RPC_URL)" ]; then echo "No RPC URL found for network $(NETWORK)"; exit 1; fi
	@echo "Testing RPC Policy deployment on $(NETWORK)..."
	DEPLOY_WHAT=rpcpolicy DEPLOY_PROXY_RPC_POLICY=true forge script script/deploy-proxies.s.sol:DeployProxiesScript \
		--rpc-url $(RPC_URL) \
		-vvv

deploy-rpcpolicy:
	@if [ -z "$(GOV_PRIVATE_KEY)" ]; then echo "GOV_PRIVATE_KEY is not set"; exit 1; fi
	@if [ -z "$(ADDRESS_HUB)" ]; then echo "ADDRESS_HUB is not set"; exit 1; fi
	@if [ -z "$(RPC_URL)" ]; then echo "No RPC URL found for network $(NETWORK)"; exit 1; fi
	@echo "Deploying RPC Policy to $(NETWORK)..."
	DEPLOY_WHAT=rpcpolicy DEPLOY_PROXY_RPC_POLICY=true forge script script/deploy-proxies.s.sol:DeployProxiesScript \
		--rpc-url $(RPC_URL) \
		--broadcast \
		-vvv

# Combined deployment targets
test-deploy: test-deploy-address-hub test-deploy-shmonad test-deploy-taskmanager test-deploy-paymaster test-deploy-rpcpolicy
	@echo "All deployment tests completed for $(NETWORK)"

# Add RPC Policy upgrade targets
test-upgrade-rpcpolicy:
	@if [ -z "$(GOV_PRIVATE_KEY)" ]; then echo "GOV_PRIVATE_KEY is not set"; exit 1; fi
	@if [ -z "$(ADDRESS_HUB)" ]; then echo "ADDRESS_HUB is not set"; exit 1; fi
	@if [ -z "$(RPC_URL)" ]; then echo "No RPC URL found for network $(NETWORK)"; exit 1; fi
	@echo "Testing RPC Policy upgrade on $(NETWORK)..."
	forge script script/upgrade-rpc-policy.s.sol:UpgradeRpcPolicyScript \
		--rpc-url $(RPC_URL) \
		-vvv

# Add paymaster ownership transfer targets
test-transfer-paymaster-ownership:
	@if [ -z "$(GOV_PRIVATE_KEY)" ]; then echo "GOV_PRIVATE_KEY is not set"; exit 1; fi
	@if [ -z "$(ADDRESS_HUB)" ]; then echo "ADDRESS_HUB is not set"; exit 1; fi
	@if [ -z "$(RPC_URL)" ]; then echo "No RPC URL found for network $(NETWORK)"; exit 1; fi
	@echo "Testing Paymaster ownership transfer on $(NETWORK)..."
	forge script script/transfer-paymaster-ownership.s.sol:TransferPaymasterOwnershipScript \
		--rpc-url $(RPC_URL) \
		-vvv

transfer-paymaster-ownership:
	@if [ -z "$(GOV_PRIVATE_KEY)" ]; then echo "GOV_PRIVATE_KEY is not set"; exit 1; fi
	@if [ -z "$(ADDRESS_HUB)" ]; then echo "ADDRESS_HUB is not set"; exit 1; fi
	@if [ -z "$(RPC_URL)" ]; then echo "No RPC URL found for network $(NETWORK)"; exit 1; fi
	@echo "Transferring Paymaster ownership on $(NETWORK)..."
	forge script script/transfer-paymaster-ownership.s.sol:TransferPaymasterOwnershipScript \
		--rpc-url $(RPC_URL) \
		--broadcast \
		-vvv

# Update the test-upgrade target to include rpcpolicy
test-upgrade: test-upgrade-address-hub test-upgrade-shmonad test-upgrade-taskmanager test-upgrade-paymaster test-upgrade-rpcpolicy
	@echo "All upgrade tests completed for $(NETWORK)"

# Update the upgrade target to include rpcpolicy
upgrade: upgrade-address-hub upgrade-shmonad upgrade-taskmanager upgrade-paymaster upgrade-rpcpolicy
	@echo "All contracts upgraded on $(NETWORK)"

# Scenarios - Safe test scripts with local forks
scenario_test_upgrade:
	@echo "Running the fork-based upgrade test scenario..."
	@script/scenarios/test-upgrades.sh

# Transaction Replay Target
replay-tx:
	@if [ -z "$(TARGET_TX_HASH)" ]; then \
		echo "Error: TARGET_TX_HASH variable must be set."; \
		echo "Usage: make replay-tx TARGET_TX_HASH=<hash> [FORK_REF_TX_HASH=<hash>] [NETWORK=<network>]"; \
		exit 1; \
	fi
	@echo "Replaying transaction $(TARGET_TX_HASH) on $(NETWORK)..."
	@CMD="./script/replay/replay-chain-tx.sh -t $(TARGET_TX_HASH)"; \
	if [ -n "$(FORK_REF_TX_HASH)" ]; then \
		CMD="$$CMD -ftx $(FORK_REF_TX_HASH)"; \
	fi; \
	RPC_TO_USE=$(firstword $($(NETWORK_UPPER)_RPC_URL) $(DEFAULT_RPC_URL)); \
	if [ -n "$(RPC_TO_USE)" ]; then \
		CMD="$$CMD -r $(RPC_TO_USE)"; \
	fi; \
	echo "Executing: $$CMD"; \
	$$CMD

# Contract Verification JSON Generation
generate-verification-json:
	@if [ -z "$(CONTRACT_ADDRESS)" ]; then \
		echo "Error: CONTRACT_ADDRESS variable must be set."; \
		echo "Usage: make generate-verification-json CONTRACT_ADDRESS=<address> CONTRACT_PATH=<path:name> [CONSTRUCTOR_ARGS=<args>]"; \
		echo ""; \
		echo "Examples:"; \
		echo "  make generate-verification-json CONTRACT_ADDRESS=0x123... CONTRACT_PATH=src/MyContract.sol:MyContract"; \
		echo "  make generate-verification-json CONTRACT_ADDRESS=0x123... CONTRACT_PATH=src/MyContract.sol:MyContract CONSTRUCTOR_ARGS=0x456..."; \
		exit 1; \
	fi
	@if [ -z "$(CONTRACT_PATH)" ]; then \
		echo "Error: CONTRACT_PATH variable must be set."; \
		echo "Usage: make generate-verification-json CONTRACT_ADDRESS=<address> CONTRACT_PATH=<path:name> [CONSTRUCTOR_ARGS=<args>]"; \
		exit 1; \
	fi
	@echo "Generating verification JSON for contract on $(NETWORK)..."
	@if [ -n "$(CONSTRUCTOR_ARGS)" ]; then \
		./script/generate-etherscan-json.sh $(CONTRACT_ADDRESS) $(CONTRACT_PATH) $(CONSTRUCTOR_ARGS); \
	else \
		./script/generate-etherscan-json.sh $(CONTRACT_ADDRESS) $(CONTRACT_PATH); \
	fi