// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import "forge-std/Test.sol";
import { VmSafe } from "forge-std/Vm.sol";

// Lib imports
import {
    TransparentUpgradeableProxy
} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import { ProxyAdmin } from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import { OwnableUpgradeable } from "@openzeppelin-upgradeable/contracts/access/OwnableUpgradeable.sol";

// Protocol Setup imports (for fork mode)
import { SetupAtlas } from "./setup/SetupAtlas.t.sol";

// Protocol imports
import { ShMonad } from "fastlane-contracts/shmonad/ShMonad.sol";
import { MockMonadStakingPrecompile } from "fastlane-contracts/shmonad/mocks/MockMonadStakingPrecompile.sol";

// Other imports
import { TestConstants } from "./TestConstants.sol";
import { UpgradeUtils } from "../../script/upgradeability/UpgradeUtils.sol";
import { JsonHelper } from "../../script/utils/JsonHelper.sol";

/**
 * @title BaseTest
 * @notice Base test contract that supports both local and fork modes
 */
contract BaseTest is
    SetupAtlas,
    TestConstants
{
    using UpgradeUtils for VmSafe;
    using JsonHelper for VmSafe;

    // Constants
    uint256 constant SCALE = 1e18;
    address internal constant STAKING_PRECOMPILE = 0x0000000000000000000000000000000000001000;

    // Test accounts
    address internal user = makeAddr("User");
    address internal deployer;
    
    // Mainnet ShMonad proxy
    address internal forkShMonadProxy = MAINNET_SHMONAD_PROXY;

    // Core contracts
    ShMonad public shMonad;
    MockMonadStakingPrecompile internal staking;

    // Network configuration
    string internal rpcUrl;
    uint256 internal forkBlock;
    bytes32 internal forkTxHash;
    bool internal useLocalMode;

    // Additional implementation addresses for local mode
    address internal unbondingTask;

    function setUp() public virtual {
        _setUpFork();
    }

    /**
     * @dev Setup for fork mode - uses existing contracts and upgrades
     */
    function _setUpFork() internal {
        // Original fork setup
        try vm.envString("MONAD_MAINNET_RPC_URL") returns (string memory url) {
            rpcUrl = url;
        } catch {
            revert("Fork mode requires MONAD_MAINNET_RPC_URL");
        }
        
        if (forkTxHash != bytes32(0)) {
            vm.createSelectFork(rpcUrl, forkTxHash);
        } else if (forkBlock != 0) {
            vm.createSelectFork(rpcUrl, forkBlock);
        } else {
            forkAtLastDeployOrDailyStart();
        }

        // Set consistent gas price for fork mode too
        vm.fee(1 gwei);

        _initDeployer();
        _etchStakingPrecompile();

        // Bind to existing mainnet ShMonad proxy
        shMonad = ShMonad(payable(forkShMonadProxy));
        vm.label(address(shMonad), "ShMonad");
        // Setup other contracts
        SetupAtlas.__setUpAtlas(deployer, shMonad, false);
    }

    function _initDeployer() internal {
        if (deployer == address(0)) {
            deployer = makeAddr("Deployer");
            vm.deal(deployer, 10_000 ether);
            vm.label(deployer, "Deployer");
        }
    }

    function _etchStakingPrecompile() internal {
        MockMonadStakingPrecompile tempStakingMock = new MockMonadStakingPrecompile();
        vm.etch(STAKING_PRECOMPILE, address(tempStakingMock).code);
        staking = MockMonadStakingPrecompile(payable(STAKING_PRECOMPILE));
        vm.label(STAKING_PRECOMPILE, "MonadStakingPrecompile");
    }


    function forkAtLastDeployOrDailyStart() internal {
        uint256 lastDeployPlus1 = VmSafe(vm).getLastDeployBlock({isMainnet: false}) + 1;

        vm.createSelectFork(rpcUrl);
        uint256 head = block.number;

        // start of current 24 hr window
        uint256 dailyStart = head - (head % BLOCK_PIN_DURATION);
        forkBlock = dailyStart > lastDeployPlus1 ? dailyStart : lastDeployPlus1;

        vm.createSelectFork(rpcUrl, uint64(forkBlock));
    }
}

// ============================================
// Mock Contracts
// ============================================

// Mock implementation for circular dependencies
contract MockImpl is OwnableUpgradeable {
    function initialize(address owner) public reinitializer(1) {
        __Ownable_init(owner);
    }
}
