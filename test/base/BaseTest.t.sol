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
import { AddressHub } from "../../src/common/AddressHub.sol";
import { Directory } from "../../src/common/Directory.sol";
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
    address internal deployer = TESTNET_FASTLANE_DEPLOYER;
    
    // Mainnet ShMonad proxy
    address internal forkShMonadProxy = MAINNET_SHMONAD_PROXY;

    // Core contracts
    AddressHub internal addressHub;
    ProxyAdmin internal addressHubProxyAdmin;
    address internal addressHubImpl;
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

        _etchStakingPrecompile();

        // Deploy AddressHub and migrate pointers
        __setUpAddressHub();

        // Bind to existing mainnet ShMonad proxy
        shMonad = ShMonad(payable(forkShMonadProxy));
        vm.label(address(shMonad), "ShMonad");
        // Setup other contracts
        SetupAtlas.__setUpAtlas(deployer, addressHub, shMonad, false);
    }

    function _etchStakingPrecompile() internal {
        MockMonadStakingPrecompile tempStakingMock = new MockMonadStakingPrecompile();
        vm.etch(STAKING_PRECOMPILE, address(tempStakingMock).code);
        staking = MockMonadStakingPrecompile(payable(STAKING_PRECOMPILE));
        vm.label(STAKING_PRECOMPILE, "MonadStakingPrecompile");
    }


    // Original fork setup functions
    function __setUpAddressHub() internal {
        // Deploy AddressHub implementation
        addressHubImpl = address(new AddressHub());

        TransparentUpgradeableProxy proxy;
        bytes memory initCalldata = abi.encodeWithSignature("initialize(address)", deployer);

        // Deploy AddressHub's Proxy contract
        (proxy, addressHubProxyAdmin) = VmSafe(vm).deployProxy(addressHubImpl, deployer, initCalldata);

        // Set addressHub var to the proxy
        addressHub = AddressHub(address(proxy));

        // No special handling needed here for local mode
        // The mocking will be done in individual test setups that need it

        // Verify deployer is owner
        require(addressHub.isOwner(deployer), "Deployer should be AddressHub owner");
        
        // Only migrate pointers in fork mode
        if (!useLocalMode) {
            __migratePointers();
        }
    }

    function __migratePointers() internal {
        vm.startPrank(deployer);
        addressHub.addPointerAddress(Directory._SHMONAD, MAINNET_SHMONAD_PROXY, "shMonad");
        vm.stopPrank();
    }

    /**
     * @dev Mock the testnet AddressHub at the hardcoded address for GasRelayConstants
     * This is needed for tests that deploy contracts inheriting from GasRelayConstants
     */
    function mockTestnetAddressHub() internal {
        if (!useLocalMode) return; // Only needed in local mode
        
        address EXPECTED_ADDRESS_HUB = 0xC9f0cDE8316AbC5Efc8C3f5A6b571e815C021B51;
        
        // // Mock shMonad() call
        // vm.mockCall(
        //     EXPECTED_ADDRESS_HUB,
        //     abi.encodeWithSelector(AddressHub.shMonad.selector),
        //     abi.encode(address(shMonad))
        // );
        
        // Mock atlas() call
        address atlasAddress = addressHub.getAddressFromPointer(Directory._ATLAS);
        vm.mockCall(
            EXPECTED_ADDRESS_HUB,
            abi.encodeWithSelector(AddressHub.atlas.selector),
            abi.encode(atlasAddress)
        );
        
        // vm.mockCall(
        //     EXPECTED_ADDRESS_HUB,
        //     abi.encodeWithSelector(AddressHub.getAddressFromPointer.selector, Directory._SHMONAD),
        //     abi.encode(address(shMonad))
        // );
        
        vm.mockCall(
            EXPECTED_ADDRESS_HUB,
            abi.encodeWithSelector(AddressHub.getAddressFromPointer.selector, Directory._ATLAS),
            abi.encode(atlasAddress)
        );
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

    /**
     * @dev Helper to skip tests that require forking
     */
    modifier skipIfLocal() {
        if (useLocalMode) {
            vm.skip(true);
        }
        _;
    }

    /**
     * @dev Helper to skip tests that require local setup
     */
    modifier skipIfFork() {
        if (!useLocalMode) {
            vm.skip(true);
        }
        _;
    }

    // function _currentAtomicLiquidity() internal view returns (uint256 liq) {
    //     try shMonad.getCurrentLiquidity() returns (uint256 value) {
    //         liq = value;
    //     } catch {
    //         liq = 0;
    //     }
    // }

    // function _ensureAtomicLiquidity(uint256 minLiquidity, uint256 targetPercent, uint256 depositAmount) internal {
    //     uint256 currentLiquidity = _currentAtomicLiquidity();
    //     if (currentLiquidity >= minLiquidity) return;

    //     uint256 requiredDeposit = depositAmount;
    //     if (requiredDeposit == 0 && minLiquidity > currentLiquidity) {
    //         requiredDeposit = minLiquidity - currentLiquidity;
    //     }

    //     if (targetPercent > 0 || requiredDeposit > 0) {
    //         vm.startPrank(deployer);
    //         if (targetPercent > 0) shMonad.setPoolTargetLiquidityPercentage(targetPercent);
    //         if (requiredDeposit > 0) {
    //             if (deployer.balance < requiredDeposit) {
    //                 vm.deal(deployer, requiredDeposit);
    //             }
    //             shMonad.deposit{ value: requiredDeposit }(requiredDeposit, deployer);
    //         }
    //         vm.stopPrank();
    //     }

    //     _advanceMockEpoch();
    //     vm.prank(governanceEOA);
    //     shMonad.crank();

    //     require(_currentAtomicLiquidity() >= minLiquidity, "Atomic pool liquidity seeding failed");
    // }
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
