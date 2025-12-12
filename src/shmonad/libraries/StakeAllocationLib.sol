//SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.8.28 <0.9.0;

import { FixedPointMathLib as Math } from "@solady/utils/FixedPointMathLib.sol";

import { CashFlows, PendingBoost, Epoch, StakingEscrow, WorkingCapital, ValidatorData } from "../Types.sol";
import { MIN_VALIDATOR_DEPOSIT, DUST_THRESHOLD } from "../Constants.sol";

library StakeAllocationLib {
    using Math for uint256;

    /// @dev Average of two unsigned integers.
    function _avg(uint256 a, uint256 b) private pure returns (uint256) {
        return (a + b) / 2;
    }

    /// @dev Saturating subtraction: returns a - b if a > b, else 0.
    function _saturatingSub(uint256 a, uint256 b) private pure returns (uint256) {
        return a > b ? a - b : 0;
    }

    /// @notice Computes a validator's stake delta for the current epoch.
    /// @dev Combines:
    ///  (1) cash-flow driven increases proportional to smoothed earned revenue share,
    ///  (2) cash-flow driven decreases proportional to available-to-unstake capacity,
    ///  (3) withdrawal dust/rounding protections.
    /// Global has been cranked already when this runs; use Last/LastLast epochs accordingly.
    /// @param globalCashFlows_Last Global cash flows for last epoch.
    /// @param globalRewards_LastLast Global rewards from two epochs ago (for smoothing).
    /// @param globalRewards_Last Global rewards from last epoch (for smoothing).
    /// @param validatorRewards_LastLast Validator rewards from two epochs ago (for smoothing).
    /// @param validatorRewards_Last Validator rewards from last epoch (for smoothing).
    /// @param validatorEpoch_Last Validator's last completed epoch view (target stake reference).
    /// @param validatorAmountAvailableToUnstake Per-validator liquid amount available to unstake now.
    /// @param globalAmountAvailableToUnstake Global liquid amount available to unstake now.
    /// @return targetValidatorStake New validator target stake for current epoch window.
    /// @return netAmount Absolute delta magnitude (increase or decrease).
    /// @return isWithdrawal True when delta is a decrease (unstake), false when increase (stake).
    function calculateValidatorEpochStakeDelta(
        CashFlows memory globalCashFlows_Last,
        PendingBoost memory globalRewards_LastLast,
        PendingBoost memory globalRewards_Last,
        PendingBoost memory validatorRewards_LastLast,
        PendingBoost memory validatorRewards_Last,
        Epoch memory validatorEpoch_Last,
        uint256 validatorAmountAvailableToUnstake,
        uint256 globalAmountAvailableToUnstake
    )
        internal
        pure
        returns (uint128 targetValidatorStake, uint128 netAmount, bool isWithdrawal)
    {
        // NOTE: Global has been cranked already. Validator is in the process of being cranked
        // but the validator storage has not yet been shifted forwards. Therefore,
        // Global_LastLast corresponds with Validator_Last
        uint256 _stakeAllocationIncrease;
        uint256 _stakeAllocationDecrease;

        // CASH FLOW HANDLING PORTION OF DELTA STAKE
        {
            uint256 _smoothedValidatorRevenue =
                _avg(validatorRewards_Last.earnedRevenue, validatorRewards_LastLast.earnedRevenue);
            uint256 _smoothedGlobalRevenue =
                _avg(globalRewards_Last.earnedRevenue, globalRewards_LastLast.earnedRevenue);

            if (
                _smoothedValidatorRevenue > DUST_THRESHOLD && globalCashFlows_Last.queueToStake > DUST_THRESHOLD
                    && _smoothedGlobalRevenue > 0
            ) {
                // Rounds down to avoid over-staking beyond available queueToStake
                _stakeAllocationIncrease =
                    globalCashFlows_Last.queueToStake * _smoothedValidatorRevenue / _smoothedGlobalRevenue;
            }

            if (
                globalCashFlows_Last.queueForUnstake > DUST_THRESHOLD && globalAmountAvailableToUnstake > 0
                    && validatorAmountAvailableToUnstake > 0
            ) {
                // Rounds up to avoid any shortfall in meeting total unstake requests
                _stakeAllocationDecrease = uint256(globalCashFlows_Last.queueForUnstake).mulDivUp(
                    validatorAmountAvailableToUnstake, globalAmountAvailableToUnstake
                );

                // If the calculated decrease would leave less than the min deposit, unstake the entire available amount
                if (_stakeAllocationDecrease > _saturatingSub(validatorAmountAvailableToUnstake, MIN_VALIDATOR_DEPOSIT))
                {
                    _stakeAllocationDecrease = validatorAmountAvailableToUnstake;
                }
            }
        }

        // Calculate the maximum available to be unstaked
        if (_stakeAllocationIncrease > _stakeAllocationDecrease) {
            netAmount = uint128(_stakeAllocationIncrease - _stakeAllocationDecrease);
            targetValidatorStake = validatorEpoch_Last.targetStakeAmount + netAmount;
            isWithdrawal = false;
        } else {
            netAmount = uint128(_stakeAllocationDecrease - _stakeAllocationIncrease);
            targetValidatorStake = validatorEpoch_Last.targetStakeAmount - netAmount;
            isWithdrawal = true;
        }

        return (targetValidatorStake, netAmount, isWithdrawal);
    }

    /// @notice Computes full withdrawal delta for a deactivated validator.
    /// @dev Returns a decrease equal to `amountAvailableToUnstake` and new target stake reduced by that amount.
    /// @param validatorEpoch_Last Validator's last completed epoch view (current target reference).
    /// @param amountAvailableToUnstake Liquid amount available to withdraw for the validator.
    /// @return targetValidatorStake New target stake after decrease.
    /// @return netAmount Absolute withdrawal amount.
    /// @return isWithdrawal Always true for deactivated validators.
    function calculateDeactivatedValidatorEpochStakeDelta(
        Epoch memory validatorEpoch_Last,
        uint256 amountAvailableToUnstake
    )
        internal
        pure
        returns (uint128 targetValidatorStake, uint128 netAmount, bool isWithdrawal)
    {
        netAmount = uint128(amountAvailableToUnstake);
        targetValidatorStake = validatorEpoch_Last.targetStakeAmount - netAmount;
        isWithdrawal = true;
        return (targetValidatorStake, netAmount, isWithdrawal);
    }

    /// @notice Returns per-validator amount that is currently eligible to unstake.
    /// @dev Excludes pending staking from last and (optionally) last-last epochs when relevant.
    /// @param validatorEpoch_LastLast Validator epoch at n-1.
    /// @param validatorEpoch_Last Validator epoch at n.
    /// @param validatorPendingEscrow_Last Pending escrow at n.
    /// @param validatorPendingEscrow_LastLast Pending escrow at n-1.
    /// @return amount Eligible amount to unstake.
    function getValidatorAmountAvailableToUnstake(
        Epoch memory validatorEpoch_LastLast,
        Epoch memory validatorEpoch_Last,
        StakingEscrow memory validatorPendingEscrow_Last,
        StakingEscrow memory validatorPendingEscrow_LastLast
    )
        internal
        pure
        returns (uint256 amount)
    {
        amount = validatorEpoch_Last.targetStakeAmount;
        if (validatorEpoch_Last.hasDeposit) {
            uint256 _unavailable_Last = validatorPendingEscrow_Last.pendingStaking;
            amount = _saturatingSub(amount, _unavailable_Last);
        }
        if (validatorEpoch_LastLast.hasDeposit && validatorEpoch_LastLast.crankedInBoundaryPeriod) {
            uint256 _unavailable_LastLast = validatorPendingEscrow_LastLast.pendingStaking;
            amount = _saturatingSub(amount, _unavailable_LastLast);
        }
    }

    /// @notice Returns global amount currently eligible to unstake (excludes pending staking/unstaking).
    /// @dev total = staked; unavailable = pendingStaking + pendingUnstaking; amount = total - unavailable (saturating).
    /// @param globalCapital_Rolling Working capital snapshot.
    /// @param globalPending_Rolling Global pending escrow snapshot.
    /// @return amount Eligible global amount to unstake.
    function getGlobalAmountAvailableToUnstake(
        WorkingCapital memory globalCapital_Rolling,
        StakingEscrow memory globalPending_Rolling
    )
        internal
        pure
        returns (uint256 amount)
    {
        // MON can have four states:
        // 1. Floating, regular MON (address(this).balance))
        // 2. Pending Staking MON
        // 3. Pending Unstaking MON
        // 4. Staked, Productive MON
        // All staked, productive MON is eligible to be unstaked, thus:
        uint256 _total = globalCapital_Rolling.stakedAmount;
        uint256 _unavailable = globalPending_Rolling.pendingStaking + globalPending_Rolling.pendingUnstaking;
        // NOTE: pendingStaking and pendingUnstaking are both considered a part of the total stakedAmount.
        amount = _saturatingSub(_total, _unavailable);
    }
}
