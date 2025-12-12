// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import "forge-std/Test.sol";

import { AtlasBaseTest } from "./base/AtlasBaseTest.t.sol";
import { DummyDAppControl } from "./helpers/DummyDAppControl.sol";
import { DummyDAppControlBuilder } from "./helpers/DummyDAppControlBuilder.sol";
import { CallConfigBuilder } from "./helpers/CallConfigBuilder.sol";
import { UserOperationBuilder } from "./builders/UserOperationBuilder.sol";
import { SolverOperationBuilder } from "./builders/SolverOperationBuilder.sol";
import { DAppOperationBuilder } from "./builders/DAppOperationBuilder.sol";

import { AtlasErrors } from "../../src/atlas/types/AtlasErrors.sol";
import { IDAppControl } from "../../src/atlas/interfaces/IDAppControl.sol";
import { CallConfig } from "../../src/atlas/types/ConfigTypes.sol";

import "../../src/atlas/types/UserOperation.sol";
import "../../src/atlas/types/SolverOperation.sol";
import "../../src/atlas/types/DAppOperation.sol";

contract NoopSolver {
    function atlasSolverCall(
        address,
        address,
        address,
        uint256,
        bytes calldata,
        bytes calldata
    ) external payable { }
}

contract AtlasErrorBubbleTest is AtlasBaseTest {

    DummyDAppControl dAppControl;
    NoopSolver noopSolver;

    function _deployControl(CallConfig memory callConfig) internal returns (DummyDAppControl) {
        return new DummyDAppControlBuilder()
            .withEscrow(address(atlas))
            .withGovernance(governanceEOA)
            .withCallConfig(callConfig)
            .buildAndIntegrate(atlasVerification);
    }

    function test_AtlasErrorBubble_errorHandlingPreOpsRevertMsgBubblesThroughAtlas() public {
        // Require preOps and allow reuse so Atlas reverts and bubbles the revert payload
        CallConfig memory cfg = new CallConfigBuilder()
            .withRequirePreOps(true)
            .withReuseUserOp(true)
            .build();

        dAppControl = _deployControl(cfg);
        noopSolver = new NoopSolver();

        // Configure DAppControl to revert during preOps
        dAppControl.setPreOpsShouldRevert(true);

        // Build a minimal metacall
        UserOperation memory userOp = new UserOperationBuilder()
            .withFrom(userEOA)
            .withTo(address(atlas))
            .withValue(0)
            .withGas(1_000_000)
            .withMaxFeePerGas(tx.gasprice + 1)
            .withNonce(address(atlasVerification), userEOA)
            .withDeadline(block.number + 2)
            .withDapp(address(dAppControl))
            .withControl(address(dAppControl))
            .withCallConfig(IDAppControl(address(dAppControl)).CALL_CONFIG())
            .withDAppGasLimit(IDAppControl(address(dAppControl)).getDAppGasLimit())
            .withSolverGasLimit(IDAppControl(address(dAppControl)).getSolverGasLimit())
            .withBundlerSurchargeRate(IDAppControl(address(dAppControl)).getBundlerSurchargeRate())
            .withSessionKey(address(0))
            .withData("")
            .signAndBuild(address(atlasVerification), userPK);

        SolverOperation[] memory solverOps = new SolverOperation[](1);
        solverOps[0] = new SolverOperationBuilder()
            .withFrom(solverOneEOA)
            .withTo(address(atlas))
            .withValue(0)
            .withGas(1_000_000)
            .withMaxFeePerGas(userOp.maxFeePerGas)
            .withDeadline(userOp.deadline)
            .withSolver(address(noopSolver))
            .withControl(userOp.control)
            .withUserOpHash(userOp)
            .withBidToken(userOp)
            .withBidAmount(0)
            .withData("")
            .signAndBuild(address(atlasVerification), solverOnePK);

        DAppOperation memory dappOp = new DAppOperationBuilder()
            .withFrom(governanceEOA)
            .withTo(address(atlas))
            .withNonce(address(atlasVerification), governanceEOA)
            .withDeadline(userOp.deadline)
            .withControl(userOp.control)
            .withBundler(address(0))
            .withUserOpHash(userOp)
            .withCallChainHash(userOp, solverOps)
            .signAndBuild(address(atlasVerification), governancePK);

        uint256 gasLim = _gasLim(userOp, solverOps);

        // Execute and capture revert data
        vm.prank(userEOA);
        (bool success, bytes memory revertData) = address(atlas).call{ gas: gasLim }(
            abi.encodeCall(atlas.metacall, (userOp, solverOps, dappOp, address(0)))
        );
        
        // Metacall should revert
        assertFalse(success, "metacall should have reverted");
            assertGt(revertData.length, 8, "revert payload too short");
            // Top-level Atlas error selector must be first 4 bytes
            bytes4 top = bytes4(revertData);
            assertEq(top, AtlasErrors.PreOpsFail.selector, "top-level selector");

            // Next 4 bytes should be the ExecutionEnvironment's Atlas error selector
            // PreOpsDelegatecallFail
            bytes4 inner;
            {
                uint64 head64;
                assembly {
                    head64 := shr(192, mload(add(revertData, 32)))
                }
                inner = bytes4(uint32(head64));
            }
            assertEq(inner, AtlasErrors.PreOpsDelegatecallFail.selector, "inner EE selector");

        // Remaining bytes include the app revert payload (e.g., Error(string))
        assertGt(revertData.length, 8, "missing app payload after selectors");
    }

    function test_AtlasErrorBubble_errorHandlingUserOpDelegatecallRevertMsgBubblesThroughAtlas() public {
        // Config with needsDelegateUser = true
        CallConfig memory cfg = new CallConfigBuilder()
            .withRequirePreOps(false)
            .withReuseUserOp(true)
            .withDelegateUser(true)
            .withZeroSolvers(true)
            .build();

        dAppControl = _deployControl(cfg);
        
        // Configure DAppControl to revert during user delegatecall
        dAppControl.setUserOpShouldRevert(true);

        // Build metacall
        UserOperation memory userOp = new UserOperationBuilder()
            .withFrom(userEOA)
            .withTo(address(atlas))
            .withValue(0)
            .withGas(1_000_000)
            .withMaxFeePerGas(tx.gasprice + 1)
            .withNonce(address(atlasVerification), userEOA)
            .withDeadline(block.number + 2)
            .withDapp(address(dAppControl))
            .withControl(address(dAppControl))
            .withCallConfig(IDAppControl(address(dAppControl)).CALL_CONFIG())
            .withDAppGasLimit(IDAppControl(address(dAppControl)).getDAppGasLimit())
            .withSolverGasLimit(IDAppControl(address(dAppControl)).getSolverGasLimit())
            .withBundlerSurchargeRate(IDAppControl(address(dAppControl)).getBundlerSurchargeRate())
            .withSessionKey(address(0))
            .withData(abi.encodeWithSignature("userDelegateCall()"))
            .signAndBuild(address(atlasVerification), userPK);

        SolverOperation[] memory solverOps = new SolverOperation[](0);

        DAppOperation memory dappOp = new DAppOperationBuilder()
            .withFrom(governanceEOA)
            .withTo(address(atlas))
            .withNonce(address(atlasVerification), governanceEOA)
            .withDeadline(userOp.deadline)
            .withControl(userOp.control)
            .withBundler(address(0))
            .withUserOpHash(userOp)
            .withCallChainHash(userOp, solverOps)
            .signAndBuild(address(atlasVerification), governancePK);

        uint256 gasLim = _gasLim(userOp, solverOps);

        // Execute and verify error bubbling
        vm.prank(userEOA);
        (bool success, bytes memory revertData) = address(atlas).call{ gas: gasLim }(
            abi.encodeCall(atlas.metacall, (userOp, solverOps, dappOp, address(0)))
        );
        
        assertFalse(success, "metacall should have reverted");
        assertGt(revertData.length, 4, "revert payload too short");
        
        // Top-level Atlas error selector must be UserOpFail
        bytes4 top = bytes4(revertData);
        assertEq(top, AtlasErrors.UserOpFail.selector, "top-level selector");
    }

    // Security test: Ensure malicious solver cannot inject error data that Atlas misinterprets
    function test_AtlasErrorBubble_errorHandlingMaliciousSolverCannotSpoofAtlasErrors() public {
        // Deploy a malicious solver that tries to revert with Atlas error selectors
        MaliciousSolver maliciousSolver = new MaliciousSolver();
        
        CallConfig memory cfg = new CallConfigBuilder()
            .withRequirePreOps(false)
            .withReuseUserOp(false)
            .build();

        dAppControl = _deployControl(cfg);

        // Build metacall with malicious solver
        UserOperation memory userOp = new UserOperationBuilder()
            .withFrom(userEOA)
            .withTo(address(atlas))
            .withValue(0)
            .withGas(1_000_000)
            .withMaxFeePerGas(tx.gasprice + 1)
            .withNonce(address(atlasVerification), userEOA)
            .withDeadline(block.number + 2)
            .withDapp(address(dAppControl))
            .withControl(address(dAppControl))
            .withCallConfig(IDAppControl(address(dAppControl)).CALL_CONFIG())
            .withDAppGasLimit(IDAppControl(address(dAppControl)).getDAppGasLimit())
            .withSolverGasLimit(IDAppControl(address(dAppControl)).getSolverGasLimit())
            .withBundlerSurchargeRate(IDAppControl(address(dAppControl)).getBundlerSurchargeRate())
            .withSessionKey(address(0))
            .withData("")
            .signAndBuild(address(atlasVerification), userPK);

        SolverOperation[] memory solverOps = new SolverOperation[](1);
        solverOps[0] = new SolverOperationBuilder()
            .withFrom(solverOneEOA)
            .withTo(address(atlas))
            .withValue(0)
            .withGas(1_000_000)
            .withMaxFeePerGas(userOp.maxFeePerGas)
            .withDeadline(userOp.deadline)
            .withSolver(address(maliciousSolver))
            .withControl(userOp.control)
            .withUserOpHash(userOp)
            .withBidToken(userOp)
            .withBidAmount(0)
            .withData("")
            .signAndBuild(address(atlasVerification), solverOnePK);

        DAppOperation memory dappOp = new DAppOperationBuilder()
            .withFrom(governanceEOA)
            .withTo(address(atlas))
            .withNonce(address(atlasVerification), governanceEOA)
            .withDeadline(userOp.deadline)
            .withControl(userOp.control)
            .withBundler(address(0))
            .withUserOpHash(userOp)
            .withCallChainHash(userOp, solverOps)
            .signAndBuild(address(atlasVerification), governancePK);

        uint256 gasLim = _gasLim(userOp, solverOps);

        // Execute - solver failure should be caught and not cause metacall to revert
        vm.prank(userEOA);
        (bool success,) = address(atlas).call{ gas: gasLim }(
            abi.encodeCall(atlas.metacall, (userOp, solverOps, dappOp, address(0)))
        );
        
        // Metacall should succeed despite malicious solver
        assertTrue(success, "metacall should succeed despite malicious solver");
    }
}

// Malicious solver that tries to spoof Atlas errors
contract MaliciousSolver {
    function atlasSolverCall(
        address,
        address,
        address,
        uint256,
        bytes calldata,
        bytes calldata
    ) external payable {
        // Try to revert with an Atlas error selector
        assembly {
            let ptr := mload(0x40)
            mstore(ptr, 0x1a91a83900000000000000000000000000000000000000000000000000000000) // PreOpsFail selector
            mstore(add(ptr, 0x04), 0x4d616c6963696f757300000000000000000000000000000000000000000000) // "Malicious" string
            revert(ptr, 0x24)
        }
    }
}
