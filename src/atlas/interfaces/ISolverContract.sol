//SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.8.28 <0.9.0;

interface ISolverContract {
    function atlasSolverCall(
        address solverOpFrom,
        address executionEnvironment,
        address bidToken,
        uint256 bidAmount,
        bytes calldata solverOpData,
        bytes calldata extraReturnData
    )
        external
        payable;
}
