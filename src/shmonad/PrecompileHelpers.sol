//SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.8.28 <0.9.0;

import { FixedPointMathLib as Math } from "@solady/utils/FixedPointMathLib.sol";
import { SafeCastLib } from "@solady/utils/SafeCastLib.sol";

import { IMonadStaking } from "./interfaces/IMonadStaking.sol";
import { DUST_THRESHOLD, UNKNOWN_VAL_ID } from "./Constants.sol";

abstract contract PrecompileHelpers {
    using SafeCastLib for uint256;
    using Math for uint256;

    // ================================================== //
    //             Staking Precompile Helpers             //
    // ================================================== //

    // We always pull rewards rather than compound them in a validator
    function _claimRewards(uint64 valId) internal expectsStakingRewards returns (uint120 rewardAmount, bool success) {
        uint256 _balance = address(this).balance;
        try STAKING_PRECOMPILE().claimRewards(valId) returns (bool precompileSuccess) {
            if (!precompileSuccess) {
                return (0, false);
            }
            rewardAmount = uint120(address(this).balance - _balance);
            return (rewardAmount, true);
        } catch {
            // Validator may not have an active delegation yet; skip without reverting
            return (0, false);
        }
    }

    function _initiateWithdrawal(
        uint64 valId,
        uint128 withdrawalAmount,
        uint8 withdrawalId
    )
        internal
        returns (bool success, uint128)
    {
        uint256 _withdrawalAmount = uint256(withdrawalAmount);
        try STAKING_PRECOMPILE().undelegate(valId, _withdrawalAmount, withdrawalId) returns (bool precompileSuccess) {
            if (!precompileSuccess) {
                return (false, 0);
            }
            return (true, withdrawalAmount);
        } catch {
            try STAKING_PRECOMPILE().getDelegator(valId, address(this)) returns (
                uint256 stake, uint256, uint256, uint256, uint256, uint64, uint64
            ) {
                if (stake > 0) {
                    if (stake < _withdrawalAmount) {
                        // NOTE: Ideally we would never reach this point, but we should aim to handle it so that we can
                        // handle emergency Monad hard forks that
                        // impact staking and that occur faster than our upgrade window will allow us to upgrade ShMonad
                        // source code. The most likely
                        // scenario is handling slashing.
                        _withdrawalAmount = stake;
                        try STAKING_PRECOMPILE().undelegate(valId, _withdrawalAmount, withdrawalId) returns (
                            bool retrySuccess
                        ) {
                            if (!retrySuccess) {
                                return (false, 0);
                            }
                            return (true, _withdrawalAmount.toUint128());
                        } catch {
                            // Pass - If we cant withdraw our staked amount, consider it a failure.
                        }
                    } else {
                        // Pass - If we cant withdraw our staked amount, consider it a failure.
                    }
                } else {
                    // Count it as a success if we're seeing a zero balance because hey at least we can see it. Silver
                    // lining.
                    return (true, 0);
                }
            } catch {
                // Pass - count it as a faillure because we can't even see our delegation
            }
        }
        return (false, 0);
    }

    function _initiateStaking(
        uint64 valId,
        uint128 stakingAmount
    )
        internal
        returns (bool success, uint128 amountStaked)
    {
        // stakingAmount should never be more than the contract balance.
        assert(stakingAmount <= address(this).balance);

        if (stakingAmount > DUST_THRESHOLD) {
            try STAKING_PRECOMPILE().delegate{ value: stakingAmount }(valId) returns (bool precompileSuccess) {
                if (!precompileSuccess) {
                    return (false, 0);
                }
                return (true, stakingAmount);
            } catch {
                return (false, 0);
            }
        } else {
            return (true, 0);
        }
    }

    function _completeWithdrawal(
        uint64 valId,
        uint8 withdrawalId
    )
        internal
        expectsUnstakingSettlement
        returns (uint128 withdrawalAmount, bool success, bool delayed)
    {
        uint256 _balance = address(this).balance;
        try STAKING_PRECOMPILE().withdraw(valId, withdrawalId) returns (bool precompileSuccess) {
            if (!precompileSuccess) {
                // Precompile rejected the withdrawal, check if it's delayed
                try STAKING_PRECOMPILE().getWithdrawalRequest(valId, address(this), withdrawalId) returns (
                    uint256 amountRaw, uint256, uint64
                ) {
                    if (amountRaw > 0) delayed = true;
                    withdrawalAmount = amountRaw.toUint128();
                } catch {
                    withdrawalAmount = 0;
                }
                return (withdrawalAmount, false, delayed);
            }
            withdrawalAmount = (address(this).balance - _balance).toUint128();
            success = true;
        } catch {
            try STAKING_PRECOMPILE().getWithdrawalRequest(valId, address(this), withdrawalId) returns (
                uint256 amountRaw, uint256, uint64
            ) {
                if (amountRaw > 0) delayed = true;
                withdrawalAmount = amountRaw.toUint128();
            } catch {
                // TODO: Handle by verifying DelInfo via getDelegator?
                // NOTE: In reality we should never reach this point, but we should aim to handle it so that we can
                // handle emergency Monad hard forks that
                // impact staking and that occur faster than our upgrade window will allow us to upgrade ShMonad source
                // code. The most likely
                // scenario is handling slashing.
                withdrawalAmount = 0;
            }
            success = false;
        }
        return (withdrawalAmount, success, delayed);
    }

    function _sendRewards(uint64 valId, uint128 rewardAmount) internal returns (bool success, uint120 amountSent) {
        // This is for debugging
        uint256 _amount = uint256(rewardAmount);
        if (_amount > address(this).balance) {
            _amount = address(this).balance;
        }

        if (_amount > DUST_THRESHOLD) {
            try STAKING_PRECOMPILE().externalReward{ value: _amount }(valId) returns (bool precompileSuccess) {
                if (!precompileSuccess) {
                    return (false, 0);
                }
                return (true, uint120(_amount));
            } catch {
                return (false, 0);
            }
        } else {
            return (true, 0);
        }
    }

    function _getEpoch() internal returns (uint64) {
        (uint64 _epoch,) = STAKING_PRECOMPILE().getEpoch();
        return _epoch;
    }

    function _getEpochBarrierAdj() internal returns (uint64) {
        (uint64 _epoch, bool _inEpochDelayPeriod) = STAKING_PRECOMPILE().getEpoch();
        if (_inEpochDelayPeriod) ++_epoch;
        return _epoch;
    }

    function _inEpochDelayPeriod() internal returns (bool) {
        (, bool _inEpochDelayPeriod) = STAKING_PRECOMPILE().getEpoch();
        return _inEpochDelayPeriod;
    }

    /// @notice Helper to fetch current validator ID from precompile with safe fallback
    /// @dev Returns UNKNOWN_VAL_ID if the call reverts or returns 0
    function _getCurrentValidatorId() internal returns (uint64 validatorId) {
        // TODO re-enable this when this function is available on Monad testnet
        // try STAKING_PRECOMPILE().getCurrentValidatorId() returns (uint64 _valId) {
        //     validatorId = _valId;
        // } catch {
        //     return uint64(UNKNOWN_VAL_ID);
        // }

        // NOTE: temporary workaround until Monad precompile supports getCurrentValidatorId()
        validatorId = _validatorIdForCoinbase(block.coinbase);

        return validatorId == 0 ? uint64(UNKNOWN_VAL_ID) : validatorId;
    }

    // ================================================== //
    //                   Virtual Methods                  //
    // ================================================== //

    function STAKING_PRECOMPILE() public pure virtual returns (IMonadStaking);

    modifier expectsUnstakingSettlement() virtual;
    modifier expectsStakingRewards() virtual;

    function _totalEquity(bool deductRecentRevenue) internal view virtual returns (uint256);
    function _validatorIdForCoinbase(address coinbase) internal view virtual returns (uint64);
}
