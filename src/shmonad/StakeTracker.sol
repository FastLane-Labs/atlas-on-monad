//SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.8.28 <0.9.0;

import { FixedPointMathLib as Math } from "@solady/utils/FixedPointMathLib.sol";
import { SafeTransferLib } from "@solady/utils/SafeTransferLib.sol";
import { SafeCastLib } from "@solady/utils/SafeCastLib.sol";

import { ValidatorRegistry } from "./ValidatorRegistry.sol";
import {
    Epoch,
    PendingBoost,
    CashFlows,
    UserUnstakeRequest,
    ValidatorStats,
    StakingEscrow,
    AtomicCapital,
    ValidatorData,
    ValidatorDataStorage,
    WorkingCapital,
    CashFlowType,
    CurrentLiabilities,
    AdminValues,
    RevenueSmoother
} from "./Types.sol";
import { StakeAllocationLib } from "./libraries/StakeAllocationLib.sol";
import { StorageLib } from "./libraries/StorageLib.sol";
import { IMonadStaking } from "./interfaces/IMonadStaking.sol";
import { ICoinbase } from "./interfaces/ICoinbase.sol";
import {
    MIN_VALIDATOR_DEPOSIT,
    SCALE,
    TARGET_FLOAT,
    STAKING,
    SHMONAD_VALIDATOR_DEACTIVATION_PERIOD,
    FLOAT_PLACEHOLDER,
    FLOAT_REBALANCE_SENSITIVITY,
    BPS_SCALE,
    EPOCHS_TRACKED,
    UINT120_MASK,
    DUST_THRESHOLD,
    UNKNOWN_VAL_ID,
    UNKNOWN_VAL_ADDRESS,
    LAST_VAL_ADDRESS,
    FIRST_VAL_ADDRESS
} from "./Constants.sol";

import { AccountingLib } from "./libraries/AccountingLib.sol";

/// @notice Consolidated StakeTracker using Monad precompile epochs and a single crank() entrypoint.
/// @dev Removes legacy startNextEpoch()/queue/bitmap flows; relies on _crankGlobal + _crankActiveValidators.
abstract contract StakeTracker is ValidatorRegistry {
    using SafeTransferLib for address;
    using SafeCastLib for uint256;
    using SafeCastLib for uint128;
    using Math for uint256;
    using AccountingLib for WorkingCapital;
    using AccountingLib for AtomicCapital;
    using AccountingLib for CurrentLiabilities;
    using StorageLib for CashFlows;
    using StorageLib for StakingEscrow;
    using StorageLib for PendingBoost;

    // ================================================== //
    //                        Init                        //
    // ================================================== //

    /// @notice Initializes the StakeTracker contract with initial state and validator setup
    /// @dev Sets up the initial epoch structure, registers placeholder validators, and initializes global state
    function __StakeTracker_init() internal {
        if (globalEpochPtr_N(0).epoch != 0) return;

        if (s_admin.internalEpoch == 0) {
            // Register the "unregistered" validator placeholder
            s_valLinkNext[FIRST_VAL_ADDRESS] = LAST_VAL_ADDRESS;
            s_valLinkPrevious[LAST_VAL_ADDRESS] = FIRST_VAL_ADDRESS;
            _addValidator(UNKNOWN_VAL_ID, UNKNOWN_VAL_ADDRESS);
            s_nextValidatorToCrank = UNKNOWN_VAL_ADDRESS;

            // Do not count the placeholder validator as an active validator
            // for purposes of rolling stake / unstake queue forward
            --s_activeValidatorCount;

            s_validatorData[UNKNOWN_VAL_ID].inActiveSet_Last = true;
            s_validatorData[UNKNOWN_VAL_ID].inActiveSet_Current = true;

            // we initialize the epoch to 10 to avoid the first epoch being 0, which is not valid.
            // internal, the epoch is independent of the monad epoch.
            uint64 _currentEpoch = 10;

            globalEpochPtr_N(-2).epoch = _currentEpoch - 2;
            globalEpochPtr_N(-1).epoch = _currentEpoch - 1;
            globalEpochPtr_N(0).epoch = _currentEpoch;

            // Start s_admin off as the current monad epoch
            // NOTE: They will diverge over time.
            s_admin.internalEpoch = _currentEpoch;
            s_pendingTargetAtomicLiquidityPercent = TARGET_FLOAT;

            for (int256 i; i < int256(EPOCHS_TRACKED); i++) {
                globalRewardsPtr_N(i).alwaysTrue = true;
                globalCashFlowsPtr_N(i).alwaysTrue = true;
            }

            uint256 _goodwill = s_globalCapital.goodwill(s_atomicAssets, globalCashFlowsPtr_N(0), address(this).balance);

            // this is a hack to get the legacy balance into the system. We should remove this migration after the
            // initial testnet upgrade.
            if (_goodwill > 0) {
                (bool _delegationsDone,, uint64[] memory _delegatedValidators) =
                    STAKING.getDelegations(address(this), 0);
                if (!_delegationsDone) revert LegacyDelegationsPaginationIncomplete();
                if (_delegatedValidators.length != 0) revert LegacyDelegationsDetected();

                if (s_globalCapital.stakedAmount != 0 || s_globalCapital.reservedAmount != 0) {
                    revert LegacyStakeDetected();
                }
                if (
                    s_globalLiabilities.rewardsPayable != 0 || s_globalLiabilities.redemptionsPayable != 0
                        || s_admin.commissionPayable != 0
                ) {
                    revert LegacyLiabilitiesDetected();
                }
                if (s_atomicAssets.allocatedAmount != 0 || s_atomicAssets.distributedAmount != 0) {
                    revert LegacyAtomicStateDetected();
                }
                globalCashFlowsPtr_N(0).queueToStake += _goodwill.toUint120();
            }

            _crankGlobal();
            _crankValidators();
        }
    }

    // ================================================== //
    //                `receive()` Function                //
    // ================================================== //

    /// @notice Handles incoming ETH payments and classifies them for proper accounting
    /// @dev Processes received ETH and updates transient capital tracking for staking operations
    receive() external payable {
        (CashFlowType flowType, uint256 existingAmountIn, uint256 lastKnownBalance) = _getTransientCapital();

        // Goodwill is the null type of CashFlowType
        if (flowType == CashFlowType.Goodwill) {
            // NOTE: must clear if contract does any payments in between receives.
            if (address(this).balance >= lastKnownBalance + msg.value) {
                globalCashFlowsPtr_N(0).queueToStake += msg.value.toUint120();
            }
        }
        _setTransientCapital(flowType, existingAmountIn + msg.value);
    }

    // t_cashFlowClassifier pack layout (uint256):
    // [255..128] lastKnownBalance
    // [127..8]   existingAmountIn (uint120)
    // [7..0]     flowType (CashFlowType as uint8)
    /// @notice Retrieves current transient capital state for cash flow classification
    /// @return flowType The type of cash flow currently being processed
    /// @return existingAmountIn The amount already processed in the current flow
    /// @return lastKnownBalance The last recorded contract balance
    function _getTransientCapital()
        internal
        view
        returns (CashFlowType flowType, uint256 existingAmountIn, uint256 lastKnownBalance)
    {
        uint256 _checkValue = t_cashFlowClassifier;
        flowType = CashFlowType(uint8(_checkValue));
        existingAmountIn = (_checkValue >> 8) & UINT120_MASK;
        lastKnownBalance = _checkValue >> 128;
    }

    /// @notice Updates transient capital state with new flow type and amount
    /// @param flowType The type of cash flow being processed
    /// @param existingAmount The amount to set for the current flow
    function _setTransientCapital(CashFlowType flowType, uint256 existingAmount) internal {
        require(existingAmount <= type(uint120).max, WillOverflowOnBitshift());
        uint256 _setValue = (address(this).balance << 128) | existingAmount << 8 | uint256(uint8(flowType));
        t_cashFlowClassifier = _setValue;
    }

    /// @notice Clears transient capital state and resets cash flow classification
    /// @dev This also deletes the last known balance - watch out!
    function _clearTransientCapital() internal {
        t_cashFlowClassifier = 0;
    }

    // ================================================== //
    //                 Crank Entry Point                  //
    // ================================================== //

    /// @notice Single public entrypoint to advance global + per-validator state
    /// Can be called by anyone, timing does not affect the outcome.
    /// @dev Processes global epoch advancement and validator state updates
    /// @return complete True if all cranking operations completed successfully
    function crank() public notWhenFrozen returns (bool complete) {
        complete = _crankGlobal();
        if (!complete) {
            complete = _crankValidators();
        }
    }

    /// @notice Processes validator state updates for all validators
    /// @dev Iterates through validators and updates their state within gas limits
    /// @return allValidatorsCranked True if all validators were processed successfully
    function _crankValidators() internal returns (bool allValidatorsCranked) {
        address _nextValidatorToCrank = s_nextValidatorToCrank;

        // TODO: calculate the actual gas needed per validator crank
        while (gasleft() > 1_000_000) {
            if (_nextValidatorToCrank == LAST_VAL_ADDRESS) break;
            _crankValidator(_nextValidatorToCrank);
            _nextValidatorToCrank = s_valLinkNext[_nextValidatorToCrank];
        }

        s_nextValidatorToCrank = _nextValidatorToCrank;
        return _nextValidatorToCrank == LAST_VAL_ADDRESS;
    }

    // ================================================== //
    //        Core Crank Functions & Accounting           //
    // ================================================== //

    /// @notice Advances global epoch state and updates global accounting in one pass.
    /// @dev Steps (ordering matters):
    ///  1) Prime next epoch storage (carry flags, compute target stake)
    ///  2) Offset uncovered liabilities using deposits (queueToStake vs queueForUnstake vs currentAssets)
    ///  3) Reconcile atomic pool accounting without changing utilization jumps
    ///  4) Carry over atomic-unstake into the global unstake queue
    ///  5) Apply goodwill (unexpected donations) into stake queue
    ///  6) Clamp queues to stakable/unstakable capacity (or roll excess forward)
    ///  7) Update revenue smoother and bump internal epoch
    ///  8) Reset validator cursor to start of linked list
    /// Returns false early if monad epoch did not advance or validators are still pending from prior round.
    /// @return complete True if global crank completed (epoch advanced and validators ready to crank)
    function _crankGlobal() internal returns (bool complete) {
        uint64 _monadEpoch = _getEpoch();

        // All validators must have finished cranking in the previous round
        if (s_nextValidatorToCrank != LAST_VAL_ADDRESS) return false;

        // Monad epoch must have increased
        if (globalEpochPtr_N(0).epoch >= _monadEpoch) return true;

        // Calculate target and prime next epoch
        uint128 _targetAmount = _computeNextTargetStakeAmount();

        // Load the just-ended epoch's data into memory to help with rolling the epoch forwards
        Epoch memory _epochThatJustEnded = globalEpochPtr_N(0);

        _primeNextGlobalEpoch(_targetAmount, _epochThatJustEnded);

        // Prepare the upcoming epoch's data by zeroing out any previous values and setting any carryovers.
        globalRewardsPtr_N(2).clear();
        globalCashFlowsPtr_N(2).clear();

        // Handle any net staking allocations to the reserved MON amount
        _offsetLiabilitiesWithDeposits();

        // Update (if applicable) and adjust the global net cash flow (MON) for flows to the atomic unstaking pool,
        // while being sure to keep the utilization rate unchanged.
        _settleGlobalNetMONAgainstAtomicUnstaking();

        // Calculate and carry forward the unstaking aount from the atomic unstaking pool
        _carryOverAtomicUnstakeIntoQueue();

        // Adjust for any goodwill (unexpected donations)
        _applyGoodwillToStakeQueue();

        _clampQueuesToCapacityOrRoll();

        _updateRevenueSmootherAfterEpochChange();

        _advanceEpochPointersAndResetValidatorCursor();

        return false;
    }

    /// @notice Offsets uncovered liabilities using available deposits and current assets.
    /// @dev Increases reservedAmount and reduces both `queueToStake` and `queueForUnstake` by the settled amount.
    /// Caps by: uncovered liabilities, `queueForUnstake`, `queueToStake`, and current assets.
    function _offsetLiabilitiesWithDeposits() internal {
        uint256 _queueToStake = globalCashFlowsPtr_N(0).queueToStake;
        uint256 _queueForUnstake = globalCashFlowsPtr_N(0).queueForUnstake;

        // Check for any outstanding liabilities
        uint256 _currentLiabilities = s_globalLiabilities.currentLiabilities();
        uint256 _reserves = s_globalCapital.reservedAmount;
        uint256 _pendingUnstaking = s_globalPending.pendingUnstaking;

        if (_currentLiabilities > _reserves + _pendingUnstaking) {
            // Start with the max value of the uncovered liabilities
            uint256 _liabilitiesToSettleWithDeposits = _currentLiabilities - _reserves - _pendingUnstaking;

            // Do not settle more than is currently requested to queue for unstaking
            if (_liabilitiesToSettleWithDeposits > _queueForUnstake) {
                _liabilitiesToSettleWithDeposits = _queueForUnstake;
            }

            // Do not use more than is currently queued for staking in the settlement process
            if (_liabilitiesToSettleWithDeposits > _queueToStake) {
                _liabilitiesToSettleWithDeposits = _queueToStake;
            }

            // We can only settle with MON (currentAssets) that hasn't been allocated for another purpose
            uint256 _currentAssets = s_globalCapital.currentAssets(s_atomicAssets, address(this).balance);
            if (_liabilitiesToSettleWithDeposits > _currentAssets) {
                _liabilitiesToSettleWithDeposits = _currentAssets;
            }

            // If we have enough funds to offset, perform the offset
            if (_liabilitiesToSettleWithDeposits > 0) {
                // Increase the reserved amount
                s_globalCapital.reservedAmount += _liabilitiesToSettleWithDeposits.toUint128();
                // Implied: currentAssets -= _liabilitiesToSettleWithDeposits

                // Remove the funds from both the queueToStake and the queueForUnstake - the deposit offsets the
                // withdrawal.
                globalCashFlowsPtr_N(0).queueToStake = (_queueToStake - _liabilitiesToSettleWithDeposits).toUint120();
                globalCashFlowsPtr_N(0).queueForUnstake =
                    (_queueForUnstake - _liabilitiesToSettleWithDeposits).toUint120();
            }
        }
    }

    /// @notice Carries over atomic pool unstake amount into the global unstake queue for the current epoch.
    function _carryOverAtomicUnstakeIntoQueue() internal {
        uint120 _unstakeQueueCarryOver = _shiftAtomicPoolValuesDuringCrank().queueForUnstake;
        globalCashFlowsPtr_N(0).queueForUnstake += _unstakeQueueCarryOver;
    }

    /// @notice Applies any goodwill (unexpected donations) to the queueToStake and emits tracking event.
    function _applyGoodwillToStakeQueue() internal {
        uint256 _goodwill = s_globalCapital.goodwill(s_atomicAssets, globalCashFlowsPtr_N(0), address(this).balance);
        if (_goodwill > 0) {
            globalCashFlowsPtr_N(0).queueToStake += _goodwill.toUint120();
            emit UnexpectedGoodwill(s_admin.internalEpoch, _goodwill);
        }
    }

    /// @notice Updates revenue smoother using just-ended epoch's earnedRevenue and current block number.
    function _updateRevenueSmootherAfterEpochChange() internal {
        // Update the revenue smoother so that we can offset _totalEquity by a smoothed revenue
        // from this epoch (which will be last epoch by the end of this call).
        s_revenueSmoother = RevenueSmoother({
            earnedRevenueLast: globalRewardsPtr_N(0).earnedRevenue,
            epochChangeBlockNumber: uint64(block.number)
        });
    }

    /// @notice Advances internal epoch pointer and resets validator crank cursor to the start of the list.
    function _advanceEpochPointersAndResetValidatorCursor() internal {
        // Increase the global internal epoch.
        // NOTE: After incrementing the internal epoch:
        //      epoch_N(-1) is now epoch_N(-2)
        //      epoch_N(0) is now epoch_N(-1)
        //      epoch_N(1) is now epoch_N(0)
        // ETC...
        ++s_admin.internalEpoch;

        // Set the next validator to crank - always start off with the FIRST_VAL_ADDRESS
        s_nextValidatorToCrank = FIRST_VAL_ADDRESS;
    }

    /// @notice Computes the next target stake amount from current equity and target liquidity percent.
    function _computeNextTargetStakeAmount() internal view returns (uint128) {
        return s_globalCapital.targetStakedAmount(
            s_globalLiabilities, s_admin, address(this).balance, _scaledTargetLiquidityPercentage()
        ).toUint128();
    }

    /// @notice Primes the next global epoch storage entry with carried flags and new target.
    function _primeNextGlobalEpoch(uint128 targetAmount, Epoch memory epochThatJustEnded) internal {
        // Prepare the upcoming epoch's storage slot
        _setEpochStorage(
            globalEpochPtr_N(1),
            Epoch({
                epoch: _getEpochBarrierAdj(), // Use the potentially higher epoch check here to make sure at least one
                    // full epoch passes
                withdrawalId: 0, // unused
                hasWithdrawal: false, // unused
                hasDeposit: false, // unused
                crankedInBoundaryPeriod: _inEpochDelayPeriod(), // can probably use later on
                wasCranked: false, // bool indicating if the placeholder validator was cranked
                frozen: epochThatJustEnded.frozen,
                closed: epochThatJustEnded.closed,
                targetStakeAmount: targetAmount
            })
        );
    }

    /// @notice Advances in-active-set flags for a validator at the start of its crank.
    function _advanceActiveSetFlags(uint64 validatorId) internal {
        if (s_validatorData[validatorId].isActive) {
            s_validatorData[validatorId].inActiveSet_Last = s_validatorData[validatorId].inActiveSet_Current;
            s_validatorData[validatorId].inActiveSet_Current = true; // Assume active, adjust later if needed
        }
    }

    /// @notice Pulls validator yield and books rewards/liabilities accounting (wrapper around precompile settlement).
    function _pullAndBookYield(address coinbase, uint64 valId) internal {
        _settleEarnedStakingYield(coinbase, valId);
    }

    /// @notice Settles ready staking/unstaking edges across the last three epochs for a validator.
    function _settlePastEpochEdges(address coinbase, uint64 valId) internal {
        // Check the last three epochs for completion of staking and unstaking actions
        Epoch storage _validatorEpochPtr = validatorEpochPtr_N(-3, valId);
        if (_validatorEpochPtr.crankedInBoundaryPeriod) {
            // The "three-epochs-ago" slot should have a withdrawal if it was initiated late during the boundary period.
            if (_validatorEpochPtr.hasWithdrawal) {
                _settleCompletedStakeAllocationDecrease(
                    coinbase, valId, _validatorEpochPtr, validatorPendingPtr_N(-3, valId)
                );
            }
        }

        _validatorEpochPtr = validatorEpochPtr_N(-2, valId);
        if (!_validatorEpochPtr.crankedInBoundaryPeriod) {
            // The unstaking initiated in epoch n-2 should be ready as long as it didn't start in a boundary period
            if (_validatorEpochPtr.hasWithdrawal) {
                _settleCompletedStakeAllocationDecrease(
                    coinbase, valId, _validatorEpochPtr, validatorPendingPtr_N(-2, valId)
                );
            }
        } else {
            // The staking initiated in epoch n-2 that was delayed by the boundary period should now be ready
            if (_validatorEpochPtr.hasDeposit) {
                _handleCompleteIncreasedAllocation(_validatorEpochPtr, validatorPendingPtr_N(-2, valId));
            }
        }

        _validatorEpochPtr = validatorEpochPtr_N(-1, valId);
        if (!_validatorEpochPtr.crankedInBoundaryPeriod) {
            // The staking initiated in epoch n-1 should be ready now as long as it wasn't cranked in a boundary period
            if (_validatorEpochPtr.hasDeposit) {
                _handleCompleteIncreasedAllocation(_validatorEpochPtr, validatorPendingPtr_N(-1, valId));
            }
        }
    }

    /// @notice Pays validator rewards if eligible; otherwise handles redirection bookkeeping.
    function _payOrRedirectValidatorRewards(address coinbase, uint64 valId) internal {
        _settleValidatorRewardsPayable(coinbase, valId);
    }

    /// @notice Computes per-validator stake delta using last windows and availability snapshots.
    function _computeStakeDelta(uint64 validatorId)
        internal
        view
        returns (uint128 nextTarget, uint128 netAmount, bool isWithdrawal)
    {
        uint256 _validatorUnstakableAmount = StakeAllocationLib.getValidatorAmountAvailableToUnstake(
            validatorEpochPtr_N(-2, validatorId),
            validatorEpochPtr_N(-1, validatorId),
            validatorPendingPtr_N(-1, validatorId),
            validatorPendingPtr_N(-2, validatorId)
        );

        uint256 _globalUnstakableAmount =
            StakeAllocationLib.getGlobalAmountAvailableToUnstake(s_globalCapital, s_globalPending);

        // Assume Validator is part of the active set to get the intended weights based on staking queue values
        (nextTarget, netAmount, isWithdrawal) = StakeAllocationLib.calculateValidatorEpochStakeDelta(
            globalCashFlowsPtr_N(-1),
            globalRewardsPtr_N(-2),
            globalRewardsPtr_N(-1),
            validatorRewardsPtr_N(-2, validatorId),
            validatorRewardsPtr_N(-1, validatorId),
            validatorEpochPtr_N(-1, validatorId),
            _validatorUnstakableAmount,
            _globalUnstakableAmount
        );
    }

    /// @notice Applies the computed stake delta via skip/decrease/increase helpers and returns updated values.
    function _applyStakeDelta(
        address coinbase,
        uint64 valId,
        uint128 nextTarget,
        uint128 netAmount,
        bool isWithdrawal
    )
        internal
        returns (uint128 nextTargetOut, uint128 netAmountOut)
    {
        nextTargetOut = nextTarget;
        netAmountOut = netAmount;

        if (netAmountOut < DUST_THRESHOLD) {
            // CASE: Amount is too small to warrant staking or unstaking
            (nextTargetOut, netAmountOut) =
                _initiateStakeAllocationSkip(coinbase, valId, nextTargetOut, netAmountOut.toUint120(), isWithdrawal);
        } else if (isWithdrawal) {
            // CASE: Decrease allocation to validator
            (nextTargetOut, netAmountOut) =
                _initiateStakeAllocationDecrease(coinbase, valId, nextTargetOut, netAmountOut);
        } else {
            // CASE: Increase allocation to validator
            (nextTargetOut, netAmountOut) =
                _initiateStakeAllocationIncrease(coinbase, valId, nextTargetOut, netAmountOut);
        }
    }

    /// @notice Clamps queues to available stake/unstake capacity or rolls forward when no validators are active.
    function _clampQueuesToCapacityOrRoll() internal {
        // Handle accounting for max / min amounts that can be staked / unstaked, but only if there are
        // validators to stake / unstake with
        if (s_activeValidatorCount > 0) {
            // Calculate and carry forward any unstakable amount that cannot be covered by the global unstakable assets
            // during the next epoch. This could occur when the majority of assets are stuck in staking escrow or
            // unstaking
            // escrow.
            uint256 _globalUnstakableAmount =
                StakeAllocationLib.getGlobalAmountAvailableToUnstake(s_globalCapital, s_globalPending);
            uint256 _queuedForUnstakeAmount = globalCashFlowsPtr_N(0).queueForUnstake;
            if (_queuedForUnstakeAmount > _globalUnstakableAmount) {
                uint256 _unstakeQueueDeficit = _queuedForUnstakeAmount - _globalUnstakableAmount;

                emit UnstakingQueueExceedsUnstakableAmount(_queuedForUnstakeAmount, _globalUnstakableAmount);

                uint120 _unstakeQueueDeficit120 = _unstakeQueueDeficit.toUint120();
                globalCashFlowsPtr_N(0).queueForUnstake -= _unstakeQueueDeficit120;
                globalCashFlowsPtr_N(1).queueForUnstake += _unstakeQueueDeficit120;
            }

            uint256 _queuedToStakeAmount = globalCashFlowsPtr_N(0).queueToStake;
            uint256 _globalStakableAmount = s_globalCapital.currentAssets(s_atomicAssets, address(this).balance);
            if (_queuedToStakeAmount > _globalStakableAmount) {
                uint256 _stakeQueueSurplus = _queuedToStakeAmount - _globalStakableAmount;

                emit StakingQueueExceedsStakableAmount(_queuedToStakeAmount, _globalStakableAmount);

                uint120 _stakeQueueSurplus120 = _stakeQueueSurplus.toUint120();
                globalCashFlowsPtr_N(0).queueToStake -= _stakeQueueSurplus120;
                globalCashFlowsPtr_N(1).queueToStake += _stakeQueueSurplus120;
            }

            // Next, we add in the "turnover" / "incentive-aligning" amount to the unstaking queue. This happens after
            // the settling of deposits against withdrawals in order to promote the rebalancing even when the net
            // cashflow is flat.
            // NOTE: The "staking" portion happens when this amount finishes unstaking.
            // NOTE: We only do this if there are multiple active validators from which to rebalance between.
            if (s_activeValidatorCount > 1 && _globalUnstakableAmount > 0) {
                uint256 _incentiveAlignmentPercentage = s_admin.incentiveAlignmentPercentage;
                if (_incentiveAlignmentPercentage > 0) {
                    // Divide by four because unstaking takes two epochs and depositing takes another two epochs
                    uint256 _alignmentUnstakeAmount =
                        _globalUnstakableAmount * _incentiveAlignmentPercentage / BPS_SCALE / 4;
                    uint256 _currentUnstakeAmount = globalCashFlowsPtr_N(0).queueForUnstake;

                    // Treat the incentive-aligning portion as a floor for withdrawals that should be inclusive of
                    // existing withdrawals.
                    if (_currentUnstakeAmount < _alignmentUnstakeAmount) {
                        globalCashFlowsPtr_N(0).queueForUnstake = _alignmentUnstakeAmount.toUint120();
                    }
                }
            }

            // If there are no active validators, roll forward any balances since there wont be anyone to stake them
            // with, then net them out since performance-weighting is not relevant
        } else {
            uint256 _queueToStake = globalCashFlowsPtr_N(0).queueToStake;
            uint256 _queueForUnstake = globalCashFlowsPtr_N(0).queueForUnstake;

            emit UnexpectedNoValidators(s_admin.internalEpoch, _queueToStake, _queueForUnstake);

            if (_queueToStake > _queueForUnstake) {
                uint256 _netQueueToStake = _queueToStake - _queueForUnstake;
                globalCashFlowsPtr_N(1).queueToStake += _netQueueToStake.toUint120();
                // Implied: globalCashFlowsPtr_N(1).queueForUnstake = 0;
            } else {
                uint256 _netQueueForUnstake = _queueForUnstake - _queueToStake;
                globalCashFlowsPtr_N(1).queueForUnstake += _netQueueForUnstake.toUint120();
                // Implied: globalCashFlowsPtr_N(1).queueToStake = 0;
            }
            globalCashFlowsPtr_N(0).clear();
        }
    }

    /// @notice Processes one validator's epoch roll, yield settlement, and (un)stake delta.
    /// @dev Skips placeholder and already-cranked validators to be idempotent within an epoch.
    /// Steps:
    ///  1) Guard for sentinel/unknown/zero-id validators
    ///  2) Mark last epoch as cranked (idempotency)
    ///  3) Advance active set flags and eligibility
    ///  4) Pull and book validator yield (precompile), updating rewards/liabilities
    ///  5) Settle past epoch edges and pay or redirect rewards
    ///  6) Compute per-validator stake delta (increase/decrease)
    ///  7) Apply delta (stake or unstake), respecting availability and dust rules
    ///  8) Roll validator epoch forwards with the next target
    /// @param coinbase The validator's coinbase address to process
    function _crankValidator(address coinbase) internal {
        // If this is the constant representing the top of the chainn, skip to the next.
        if (coinbase == FIRST_VAL_ADDRESS) return;

        // Make sure we have a coinbase ↔ valId mapping before proceeding.
        uint64 _valId = s_valIdByCoinbase[coinbase];
        if (_valId == UNKNOWN_VAL_ID) {
            _crankPlaceholderValidator();
            return;
        } else if (_valId == 0) {
            return;
        }

        // Crank only once per epoch per validator and only after the global state advanced.
        Epoch storage _lastEpoch = validatorEpochPtr_N(-1, _valId);
        if (_lastEpoch.wasCranked) return;
        _lastEpoch.wasCranked = true;

        // NOTE:
        // Global has already been cranked.
        // The epoch that is currently ongoing is validatorEpochPtr_N(0, coinbase)
        // The most recent epoch that has fully completed is is validatorEpochPtr_N(-1, coinbase)

        _advanceActiveSetFlags(_valId);

        // Pull validator rewards (net of commission) so rebalancing reflects latest earnings.
        _pullAndBookYield(coinbase, _valId);

        _settlePastEpochEdges(coinbase, _valId);

        // Send any unsent rewardsPayable (i.e., MEV payments)
        _payOrRedirectValidatorRewards(coinbase, _valId);

        // Calculate and then handle the net staking / unstaking
        (uint128 _nextTargetStakeAmount, uint128 _netAmount, bool _isWithdrawal) = _computeStakeDelta(_valId);

        // CASE: Validator was tagged as inactive for the cranked period
        if (!s_validatorData[_valId].isActive) {
            uint256 _validatorUnstakableAmount = StakeAllocationLib.getValidatorAmountAvailableToUnstake(
                validatorEpochPtr_N(-2, _valId),
                validatorEpochPtr_N(-1, _valId),
                validatorPendingPtr_N(-1, _valId),
                validatorPendingPtr_N(-2, _valId)
            );
            // We're withdrawing _validatorUnstakableAmount, Roll forward any allocations that should've happened but
            // were blocked due to inactivity
            // NOTE: The difference between the previous _netAmount and the _validatorUnstakableAmount will get picked
            // up by the global crank as
            // goodwill and placed in the staking queue at that time.
            _netAmount = _validatorUnstakableAmount.toUint128();
            _nextTargetStakeAmount = 0;
            _isWithdrawal = true;
        }

        (_nextTargetStakeAmount, _netAmount) =
            _applyStakeDelta(coinbase, _valId, _nextTargetStakeAmount, _netAmount, _isWithdrawal);

        // Roll the storage slots forwards
        _rollValidatorEpochForwards(_valId, _nextTargetStakeAmount);

        // If coinbase is a contract, attempt to process it via a try/catch
        if (coinbase.code.length > 0) {
            try ICoinbase(coinbase).process() { } catch { }
        }
    }

    /// @notice Handles cranking for the placeholder validator (unregistered validators)
    /// @dev Processes revenue attribution for unregistered validators
    function _crankPlaceholderValidator() internal {
        if (globalEpochPtr_N(-1).wasCranked) return;

        emit UnregisteredValidatorRevenue(
            globalEpochPtr_N(-1).epoch,
            uint256(validatorRewardsPtr_N(0, UNKNOWN_VAL_ID).rewardsPayable),
            uint256(validatorRewardsPtr_N(0, UNKNOWN_VAL_ID).earnedRevenue)
        );

        // Set the placeholder validator as having been cranked via the global epoch
        _rollValidatorEpochForwards(UNKNOWN_VAL_ID, 0);
    }

    /// @notice Advances validator epoch state and updates validator accounting
    /// @param valId The validator's ID
    /// @param newTargetStakeAmount The new target stake amount for the validator
    function _rollValidatorEpochForwards(uint64 valId, uint128 newTargetStakeAmount) internal {
        // Load the ongoing validator epoch into memory for convenience
        Epoch memory _ongoingValidatorEpoch = validatorEpochPtr_N(0, valId);
        uint64 _internalEpoch = s_admin.internalEpoch;

        // Store the next withdrawal id after incrementing if a withdrawal was initiated during this crank.
        uint8 _withdrawalId = _ongoingValidatorEpoch.withdrawalId;
        if (_ongoingValidatorEpoch.hasWithdrawal) {
            unchecked {
                if (++_withdrawalId == 0) _withdrawalId = 1;
            }
        }

        // Set the target stake amount
        validatorEpochPtr_N(0, valId).targetStakeAmount = newTargetStakeAmount;

        // Clear out the next next shmonad epoch's slots
        validatorRewardsPtr_N(2, valId).clear();
        validatorPendingPtr_N(2, valId).clear();
        _setEpochStorage(
            validatorEpochPtr_N(1, valId),
            Epoch({
                epoch: _internalEpoch + 1,
                withdrawalId: _withdrawalId,
                hasWithdrawal: false,
                hasDeposit: false,
                crankedInBoundaryPeriod: false,
                wasCranked: false,
                frozen: _ongoingValidatorEpoch.frozen,
                closed: _ongoingValidatorEpoch.closed,
                targetStakeAmount: 0
            })
        );

        // Update ValidatorData
        if (s_validatorData[valId].isActive) {
            s_validatorData[valId].epoch = _internalEpoch;

            // Handle special deactivation logic - we don't increment the validatorData epoch if they're deactivated
            // (even though we do increment the s_validatorEpoch if they're deactivated)
            if (!s_validatorData[valId].inActiveSet_Last && !s_validatorData[valId].inActiveSet_Current) {
                _beginDeactivatingValidator(valId);
            }

            // Handle special deactivation logic - we don't increment the validatorData epoch if they're deactivated
            // (even though we do increment the s_validatorEpoch if they're deactivated)
        } else {
            // If SHMONAD_VALIDATOR_DEACTIVATION_PERIOD epochs have passed, fully remove the validator
            if (_internalEpoch >= s_validatorData[valId].epoch + SHMONAD_VALIDATOR_DEACTIVATION_PERIOD) {
                _completeDeactivatingValidator(valId);
            }
        }
    }

    /// @notice Shifts atomic pool values during global crank and returns cash flows
    /// @dev Handles atomic unstaking pool rebalancing during epoch transitions
    /// @return CashFlows memory The updated cash flow state
    function _shiftAtomicPoolValuesDuringCrank() internal returns (CashFlows memory) {
        // NOTE: We set this to globalRewards.earnedRevenue so that there is no "jump" in the fee cost
        // whenever we crank
        uint120 _amountToSettle =
            Math.min(globalRewardsPtr_N(0).earnedRevenue, s_atomicAssets.distributedAmount).toUint120();

        s_atomicAssets.distributedAmount -= _amountToSettle; // -Contra_Asset Dr _amountToSettle
        // Implied: currentAssets -= _amountToSettle; // -Asset Cr _amountToSettle
        return CashFlows({ queueToStake: 0, queueForUnstake: _amountToSettle, alwaysTrue: true });
    }

    /// @notice Checks and sets new atomic liquidity target based on current conditions
    /// @param oldAllocatedAmount The previous allocated amount for comparison
    /// @return scaledTargetPercent The new scaled target percentage
    /// @return newAllocatedAmount The new allocated amount for atomic unstaking
    function _checkSetNewAtomicLiquidityTarget(uint128 oldAllocatedAmount)
        internal
        returns (uint256 scaledTargetPercent, uint128 newAllocatedAmount)
    {
        // Load any pending atomic liquidity percentage
        uint256 _newScaledTargetPercent = s_pendingTargetAtomicLiquidityPercent;

        // Load relevant values
        WorkingCapital memory _globalCapital = s_globalCapital;
        uint256 _totalEquity = _globalCapital.totalEquity(s_globalLiabilities, s_admin, address(this).balance);
        uint256 _currentAssets = _globalCapital.currentAssets(s_atomicAssets, address(this).balance);

        // See if there is a new target percent - if not, check for minor rebalances and then return the old data.

        if (_newScaledTargetPercent == FLOAT_PLACEHOLDER) {
            // Check to see if the allocated amount has drifted too far away due to increases during
            // _accountForWithdraw
            uint256 _scaledTargetAllocatedPercentage = _scaledTargetLiquidityPercentage();
            uint256 _scaledCurrentAllocatedPercentage = _scaledPercentFromAmounts(oldAllocatedAmount, _totalEquity);

            if (_scaledTargetAllocatedPercentage > _scaledCurrentAllocatedPercentage + FLOAT_REBALANCE_SENSITIVITY) {
                // CASE: Need to rebalance up
                _newScaledTargetPercent = _scaledTargetAllocatedPercentage;
                s_pendingTargetAtomicLiquidityPercent = _scaledTargetAllocatedPercentage;
            } else if (
                // CASE: rebalance down
                _scaledTargetAllocatedPercentage + FLOAT_REBALANCE_SENSITIVITY < _scaledCurrentAllocatedPercentage
            ) {
                _newScaledTargetPercent = _scaledTargetAllocatedPercentage;
                s_pendingTargetAtomicLiquidityPercent = _scaledTargetAllocatedPercentage;
            } else {
                // CASE: Allocation is within threshold
                return (_scaledTargetAllocatedPercentage, oldAllocatedAmount);
            }
        }

        // Calculate an initial allocation amount for the atomic unstaking pool
        newAllocatedAmount = _amountFromScaledPercent(_totalEquity, _newScaledTargetPercent).toUint128();

        if (newAllocatedAmount > oldAllocatedAmount) {
            // CASE: Increasing the liquidity target
            uint128 _maxNetAmount = _currentAssets.toUint128();

            if (oldAllocatedAmount + _maxNetAmount < newAllocatedAmount) {
                // CASE: we cannot increase by the full max amount, so calculate the new scaledTargetPercent
                newAllocatedAmount = oldAllocatedAmount + _maxNetAmount;
                _newScaledTargetPercent = _scaledPercentFromAmounts(newAllocatedAmount, _totalEquity);
            } else {
                // CASE: we can increase by the full net amount, so we fully remove the
                // s_pendingTargetAtomicLiquidityPercent and consider the update complete.

                // Clear the pending target - we can fully update.
                s_pendingTargetAtomicLiquidityPercent = FLOAT_PLACEHOLDER;
            }
        } else {
            uint128 _minGrossAmount = s_atomicAssets.distributedAmount;

            if (newAllocatedAmount < _minGrossAmount) {
                // CASE: Trying to reduce beyond the utilized amount - we must adjust to avoid underflowing in other
                // calculations.

                // Apply cap and then backwards calculate the in-step target percent
                newAllocatedAmount = _minGrossAmount;
                _newScaledTargetPercent = _scaledPercentFromAmounts(newAllocatedAmount, _totalEquity);
            } else {
                // Fully remove the  s_pendingTargetAtomicLiquidityPercent
                s_pendingTargetAtomicLiquidityPercent = FLOAT_PLACEHOLDER;
            }
        }

        // Store data and return
        s_admin.targetLiquidityPercentage = _unscaledTargetLiquidityPercentage(_newScaledTargetPercent);

        return (_newScaledTargetPercent, newAllocatedAmount);
    }

    /// @notice Settles completed stake allocation changes (staking/unstaking) for a validator
    /// @param coinbase The validator's coinbase address
    /// @param valId The validator ID
    /// @param validatorEpochPtr Storage pointer to validator epoch data
    /// @param validatorPendingPtr Storage pointer to validator pending data
    function _settleCompletedStakeAllocationDecrease(
        address coinbase,
        uint64 valId,
        Epoch storage validatorEpochPtr,
        StakingEscrow storage validatorPendingPtr
    )
        internal
    {
        (uint128 _amountReceived, bool _success, bool _delayed) =
            _completeWithdrawal(valId, validatorEpochPtr.withdrawalId);
        if (_delayed) {
            // Treat boundary-period delays as cranked-in-boundary so the N(-3) path retries next epoch.
            validatorEpochPtr.crankedInBoundaryPeriod = true;
            // NOTE: This frame is just for testing purposes - it indicates a timing synchronization problem
            emit WithdrawSettlementDelayed(
                coinbase,
                valId,
                _getEpoch(),
                validatorPendingPtr.pendingUnstaking,
                _amountReceived,
                validatorEpochPtr.withdrawalId
            );
        } else if (_success) {
            _handleCompleteDecreasedAllocation(validatorEpochPtr, validatorPendingPtr, _amountReceived.toUint120());

            emit UnexpectedStakeSettlementError(coinbase, valId, _amountReceived, 1);
        } else {
            _markValidatorNotInActiveSet(valId, 2);

            emit UnexpectedStakeSettlementError(coinbase, valId, _amountReceived, 2);
        }
    }

    /// @notice Settles earned (received) staking yield from a validator
    /// @param coinbase The validator's coinbase address
    /// @param valId The validator ID
    function _settleEarnedStakingYield(address coinbase, uint64 valId) internal {
        (uint120 _amountRewarded, bool _success) = _claimRewards(valId);
        if (_success) {
            _handleEarnedStakingYield(valId, _amountRewarded);
        } else {
            _markValidatorNotInActiveSet(valId, 1);

            emit UnexpectedYieldSettlementError(coinbase, valId, _amountRewarded, address(this).balance, 1);
        }
    }

    /// @notice Settles validator rewards payable (MEV payments *TO* a validator).
    /// @param coinbase The validator's coinbase address
    /// @param valId The validator ID
    function _settleValidatorRewardsPayable(address coinbase, uint64 valId) internal {
        uint120 _validatorRewardsPayable = validatorRewardsPtr_N(-1, valId).rewardsPayable;
        if (_validatorRewardsPayable >= MIN_VALIDATOR_DEPOSIT) {
            // NOTE: if _sendRewards fails it means the validator is no longer a part of the active validator set
            (bool _success, uint120 _actualAmountSent) = _sendRewards(valId, _validatorRewardsPayable);
            if (_success) {
                if (_actualAmountSent < _validatorRewardsPayable) {
                    // NOTE: This frame is for testing - if it's triggered it signifies an underlying issue
                    emit InsufficientLocalBalance(
                        _validatorRewardsPayable, _actualAmountSent, address(this).balance, _totalEquity(false), 2
                    );
                    emit UnexpectedValidatorRewardsPayError(
                        coinbase, valId, _validatorRewardsPayable, address(this).balance, 1
                    );

                    _handleRewardsPaidFail(valId, _validatorRewardsPayable - _actualAmountSent);
                    _handleRewardsPaidSuccess(_actualAmountSent);
                } else {
                    _handleRewardsPaidSuccess(_validatorRewardsPayable);
                }
            } else {
                emit UnexpectedValidatorRewardsPayError(
                    coinbase, valId, _validatorRewardsPayable, address(this).balance, 2
                );
                _handleRewardsRedirect(_validatorRewardsPayable);
                _markValidatorNotInActiveSet(valId, 3);
            }
        } else if (_validatorRewardsPayable > 0) {
            emit UnexpectedValidatorRewardsPayError(coinbase, valId, _validatorRewardsPayable, address(this).balance, 3);
            _handleRewardsPaidFail(valId, _validatorRewardsPayable);
        }
    }

    /// @notice Handles stake allocation skip when amount is below dust threshold
    /// @param coinbase The validator's coinbase address
    /// @param valId The validator ID
    /// @param nextTargetStakeAmount The next target stake amount
    /// @param netAmount The net amount to process
    /// @param isWithdrawal Whether this is a withdrawal operation
    /// @return The updated target stake amount and net amount
    function _initiateStakeAllocationSkip(
        address coinbase,
        uint64 valId,
        uint128 nextTargetStakeAmount,
        uint120 netAmount,
        bool isWithdrawal
    )
        internal
        returns (uint128, uint120)
    {
        if (netAmount == 0) {
            // pass
            emit LowValidatorStakeDeltaNetZero(
                coinbase,
                valId,
                globalEpochPtr_N(-1).epoch,
                nextTargetStakeAmount,
                netAmount,
                s_validatorData[valId].inActiveSet_Current,
                s_validatorData[valId].inActiveSet_Last
            );
        } else if (isWithdrawal) {
            // Adjust the target, then resubmit the amount into the unstaking queue
            nextTargetStakeAmount += netAmount;
            globalCashFlowsPtr_N(0).queueForUnstake += netAmount;
            netAmount = 0;

            emit LowValidatorStakeDeltaOnDecrease(
                coinbase,
                valId,
                globalEpochPtr_N(-1).epoch,
                nextTargetStakeAmount,
                netAmount,
                s_validatorData[valId].inActiveSet_Current,
                s_validatorData[valId].inActiveSet_Last
            );
        } else {
            // Adjust the target, then resubmit the amount into the staking queue
            nextTargetStakeAmount -= netAmount;
            globalCashFlowsPtr_N(0).queueToStake += netAmount;
            netAmount = 0;

            emit LowValidatorStakeDeltaOnIncrease(
                coinbase,
                valId,
                globalEpochPtr_N(-1).epoch,
                nextTargetStakeAmount,
                netAmount,
                s_validatorData[valId].inActiveSet_Current,
                s_validatorData[valId].inActiveSet_Last
            );
        }
        return (nextTargetStakeAmount, netAmount);
    }

    /// @notice Initiates stake allocation decrease for a validator
    /// @param coinbase The validator's coinbase address
    /// @param valId The validator ID
    /// @param nextTargetStakeAmount The next target stake amount
    /// @param netAmount The net amount to decrease
    /// @return The updated target stake amount and net amount
    function _initiateStakeAllocationDecrease(
        address coinbase,
        uint64 valId,
        uint128 nextTargetStakeAmount,
        uint128 netAmount
    )
        internal
        returns (uint128, uint128)
    {
        // Kick off the next-stage unstake;
        (bool _success, uint128 _amountWithdrawing) =
            _initiateWithdrawal(valId, netAmount, validatorEpochPtr_N(0, valId).withdrawalId);

        // CASE: Unstaking initiated successfully
        if (_success) {
            // CASE: Unstaking initiated successfully but unable to initiate the intended amount
            if (_amountWithdrawing < netAmount) {
                emit InsufficientActiveDelegatedBalance(coinbase, valId, _getEpoch(), netAmount, _amountWithdrawing);

                // Readd the netAmount to the nextTargetStakeAmount and resubmit the amount to the unstaking queue.
                uint120 _deficit = (netAmount - _amountWithdrawing).toUint120();
                nextTargetStakeAmount += _deficit;
                globalCashFlowsPtr_N(0).queueForUnstake += _deficit;
                netAmount -= _deficit;
            }
            _handleInitiateDecreasedAllocation(valId, coinbase, _amountWithdrawing.toUint120());

            // CASE: Unstaking failed to initiate
        } else {
            _markValidatorNotInActiveSet(valId, 4);
            // Readd the netAmount to the nextTargetStakeAmount and resubmit the amount to the unstaking queue.
            nextTargetStakeAmount += netAmount;
            globalCashFlowsPtr_N(0).queueForUnstake += netAmount.toUint120();
            netAmount = 0;

            // Emit event
            emit UnexpectedFailureInitiateUnstake(coinbase, valId, nextTargetStakeAmount, netAmount);
        }
        return (nextTargetStakeAmount, netAmount);
    }

    /// @notice Initiates stake allocation increase for a validator
    /// @param coinbase The validator's coinbase address
    /// @param valId The validator ID
    /// @param nextTargetStakeAmount The next target stake amount
    /// @param netAmount The net amount to increase
    /// @return The updated target stake amount and net amount
    function _initiateStakeAllocationIncrease(
        address coinbase,
        uint64 valId,
        uint128 nextTargetStakeAmount,
        uint128 netAmount
    )
        internal
        returns (uint128, uint128)
    {
        // Deploy additional stake to the validator
        (bool _success, uint128 _actualAmount) = _initiateStaking(valId, netAmount);

        // CASE: Staking initiated successfully
        if (_success) {
            // CASE: Staking initiated successfully but unable to initiate the intended amount
            if (_actualAmount < netAmount) {
                // NOTE: This frame is for testing - if it's triggered it signifies an underlying issue
                emit InsufficientLocalBalance(netAmount, _actualAmount, address(this).balance, _totalEquity(false), 1);

                // Reduce the nextTargetStakeAmount and the netAmount by the missing allocation and then
                // resubmit the amount to the staking queue.
                uint120 _deficit = (netAmount - _actualAmount).toUint120();
                nextTargetStakeAmount -= _deficit;
                globalCashFlowsPtr_N(0).queueToStake += _deficit;
                netAmount = _actualAmount;
            }
            _handleInitiateIncreasedAllocation(valId, coinbase, netAmount.toUint120());

            // CASE: Staking failed to initiate
        } else {
            _markValidatorNotInActiveSet(valId, 5);

            // Remove the netAmount from the nextTargetStakeAmount and resubmit the missing amount to the staking queue.
            nextTargetStakeAmount -= netAmount;
            globalCashFlowsPtr_N(0).queueToStake += netAmount.toUint120();
            netAmount = 0;

            // Emit event
            emit UnexpectedFailureInitiateStake(coinbase, valId, nextTargetStakeAmount, netAmount);
        }
        return (nextTargetStakeAmount, netAmount);
    }

    // ================================================== //
    //       Accounting Handlers - MEV and Revenue        //
    // ================================================== //

    /// @notice Handles the accounting, collection and escrow of MEV rewards that will be paid out to a validator in the
    /// next epoch. This also collects and processes shMonad's share of the MEV payments.
    /// @param valId The validator ID
    /// @param amount The total reward amount
    /// @param feeRate The fee rate to apply
    /// @return validatorPayout The amount paid to the validator
    /// @return feeTaken The fee amount taken by the protocol
    function _handleValidatorRewards(
        uint64 valId,
        uint256 amount,
        uint256 feeRate
    )
        internal
        override
        returns (uint120 validatorPayout, uint120 feeTaken)
    {
        // NOTE: The `feeTaken` portion is earnedRevenue - realized as shMON yield immediately.
        // The validator payout after fees is delayed until the next epoch's crank is called.
        uint120 _grossFeeTaken = _amountFromScaledPercent(amount, feeRate).toUint120();
        uint256 _boostCommissionRate = s_admin.boostCommissionRate;

        uint120 _commissionTaken = (_grossFeeTaken * _boostCommissionRate / BPS_SCALE).toUint120();
        feeTaken = _grossFeeTaken - _commissionTaken;
        validatorPayout = amount.toUint120() - feeTaken - _commissionTaken;

        // Load the validator's data
        ValidatorData memory _vData = _getValidatorData(valId);

        // CASE: Validator is registered with FastLane - hold their MEV rewards (net of FastLane fee)
        // in escrow for them and pay them out next epoch.
        if (!_vData.isPlaceholder && _vData.inActiveSet_Current) {
            PendingBoost storage validatorRewardsPtr = validatorRewardsPtr_N(0, valId);
            validatorRewardsPtr.rewardsPayable += validatorPayout;
            validatorRewardsPtr.earnedRevenue += feeTaken;

            globalRewardsPtr_N(0).earnedRevenue += feeTaken;

            s_globalLiabilities.rewardsPayable += validatorPayout; // +Liability Cr validatorPayout
            s_admin.commissionPayable += _commissionTaken; // +Liability Cr _commissionTaken
            s_globalCapital.reservedAmount += validatorPayout; // +Asset Dr validatorPayout,
                // Implied currentAssets += _commissionTaken //  +Asset Dr +_commissionTaken
        } else {
            // CASE: Validator is NOT registered with FastLane - use all the MEV to boost shMON yield,
            // but don't increase the global (all validators) earnedRevenue because we don't want this
            // revenue to 'dilute' the revenue weights of the registered validators.
            PendingBoost storage validatorRewardsPtr = validatorRewardsPtr_N(0, UNKNOWN_VAL_ID);
            validatorRewardsPtr.rewardsPayable += validatorPayout;
            validatorRewardsPtr.earnedRevenue += feeTaken;

            // Treat full amount as a debit rather than revenue to avoid diluting the revenue of active validators.
            feeTaken += validatorPayout;
            validatorPayout = 0;
            s_admin.commissionPayable += _commissionTaken; // +Liability Cr _commissionTaken
            // Implied currentAssets += _commissionTaken; // +Asset Dr _commissionTaken
            // Implied currentAssets += feeTaken; // +Asset Dr feeTaken
            // Implied equity += feeTaken; // +Equity Cr feeTaken

            // Track validator activity for eligibility tracking
            _updateSelfRegEligibility(valId);
        }

        // Queue the net new unencumbered MON for staking
        globalCashFlowsPtr_N(0).queueToStake += (feeTaken + _commissionTaken);

        // Re-add _commissionTaken to feeTaken when returning the amount that doesn't go to the validator
        return (validatorPayout, feeTaken + _commissionTaken);
    }

    /// @notice Handles the accounting for contract interactions that boost shMonad's yield.
    /// @param amount The boost yield amount to distribute
    function _handleBoostYield(uint128 amount) internal override {
        // NOTE: `amount` is pure earnedRevenue - realized as shMON yield immediately.

        uint128 _grossBoostCommission = amount * s_admin.boostCommissionRate / BPS_SCALE;

        if (_grossBoostCommission > 0) {
            s_admin.commissionPayable += _grossBoostCommission; // +Liability Cr _grossBoostCommission
            // Implied: currentAssets +=  _grossBoostCommission // +Asset Dr _grossBoostCommission

            amount -= _grossBoostCommission;
        }

        // Implied currentAssets += amount; // +Asset Dr amount
        // Implied equity += amount; // +Equity Cr amount

        // Load the validator's data
        uint64 _currentValId = _getCurrentValidatorId();
        ValidatorData memory _vData = _getValidatorData(_currentValId);
        uint120 _amount120 = amount.toUint120();

        // Only increment global earned revenus if validator is not placeholder -
        // this is to prevent diluting real validators' proportional revenue-weighted allocations
        // CASE: Active, valid validator
        if (!_vData.isPlaceholder && _vData.inActiveSet_Current) {
            validatorRewardsPtr_N(0, _currentValId).earnedRevenue += _amount120;
            globalRewardsPtr_N(0).earnedRevenue += _amount120;

            // CASE: Inactive or placeholder validator
        } else {
            validatorRewardsPtr_N(0, UNKNOWN_VAL_ID).earnedRevenue += _amount120;

            // Track validator activity for eligibility tracking
            _updateSelfRegEligibility(_currentValId);
        }
        globalCashFlowsPtr_N(0).queueToStake += (amount + _grossBoostCommission).toUint120();
    }

    // ================================================== //
    //     Accounting Handlers - Validators / Crank       //
    // ================================================== //

    /// @notice Handles accounting of the initiation of increased stake allocation with a validator
    /// @param coinbase The validator's coinbase address
    /// @param amount The amount to allocate
    function _handleInitiateIncreasedAllocation(uint64 valId, address coinbase, uint120 amount) internal {
        // Method called before calling the validator

        // NOTE: This is called after any handleComplete_Allocation methods
        // Push forward but don't rotate the withdrawal ID

        // Update the target amount and flag as not having a withdrawal
        Epoch storage validatorEpochPtr = validatorEpochPtr_N(0, valId);
        validatorEpochPtr.hasDeposit = true;
        validatorEpochPtr.hasWithdrawal = false;
        validatorEpochPtr.crankedInBoundaryPeriod = _inEpochDelayPeriod();

        // Initiate ShMonad MON -> Validator
        validatorPendingPtr_N(0, valId).pendingStaking += amount;
        s_globalPending.pendingStaking += amount;
        s_globalCapital.stakedAmount += amount; // +Asset Dr amount
            // Implied currentAssets -= amount; // -Asset Cr amount
    }

    /// @notice Handles accounting of the completion of increased stake allocation with a validator
    /// @param validatorEpochPtr Storage pointer to validator epoch data
    /// @param validatorPendingPtr Storage pointer to validator pending data
    function _handleCompleteIncreasedAllocation(
        Epoch storage validatorEpochPtr,
        StakingEscrow storage validatorPendingPtr
    )
        internal
    {
        // Complete ShMonad MON -> Validator
        // validatorPendingPtr_N(-2, coinbase).pendingStaking -= amount;
        validatorEpochPtr.hasDeposit = false;
        uint120 _amount = validatorPendingPtr.pendingStaking;
        s_globalPending.pendingStaking -= _amount;
    }

    /// @notice Handles initiation of decreased stake allocation for a validator
    /// @param coinbase The validator's coinbase address
    /// @param amount The amount to deallocate
    function _handleInitiateDecreasedAllocation(uint64 valId, address coinbase, uint120 amount) internal {
        // Method called before calling the validator

        // Flag as having a withdrawal
        // NOTE: This is after any handleComplete_Allocation methods
        validatorEpochPtr_N(0, valId).hasWithdrawal = true;
        validatorEpochPtr_N(0, valId).hasDeposit = false;
        validatorEpochPtr_N(0, valId).crankedInBoundaryPeriod = _inEpochDelayPeriod();

        // Initiate Validator MON -> ShMonad
        validatorPendingPtr_N(0, valId).pendingUnstaking += amount;
        s_globalPending.pendingUnstaking += amount;
    }

    /// @notice Handles accounting of the completion of decreased stake allocation with a validator
    /// @param validatorEpochPtr Storage pointer to validator epoch data
    /// @param validatorPendingPtr Storage pointer to validator pending data
    /// @param amount The amount that was deallocated
    function _handleCompleteDecreasedAllocation(
        Epoch storage validatorEpochPtr,
        StakingEscrow storage validatorPendingPtr,
        uint120 amount
    )
        internal
    {
        // Complete Validator MON -> ShMonad
        // NOTE: Global has been cranked already. Validator is in the process of being cranked
        // but the validator storage has not yet been shifted forwards. Therefore,
        // Global_LastLast corresponds with Validator_Last
        uint256 _amount = amount; // Gives us a uint256 and a uint128 version of `amount`
        uint120 _expectedAmount = validatorPendingPtr.pendingUnstaking;

        // Adjust globals with the expected amount
        s_globalPending.pendingUnstaking -= _expectedAmount;

        // Implied currentAssets += _expectedAmount; // +Asset Dr _expectedAmount
        s_globalCapital.stakedAmount -= _expectedAmount; // -Asset Cr _expectedAmount

        // Mark withdrawal as complete
        validatorEpochPtr.hasWithdrawal = false;

        // This handles either slashing or donation attacks
        if (amount > _expectedAmount) {
            // CASE: Received more than expected
            uint120 _surplus = amount - _expectedAmount;

            // Implied currentAssets += _surplus // +Asset Dr _surplus
            // Implied equity += _surplus // +Equity Cr _surplus

            // Update global target w/ the surplus then correct the unstaking journal entry
            validatorPendingPtr.pendingUnstaking += _surplus;

            // Global accounting entries:
            // Implied currentAssets += _surplus; // +Asset Dr _expectedAmount
            // Implied equity += _surplus // +Equity Cr _surplus
            //
            // Emit event
            emit UnexpectedSurplusOnUnstakeSettle(_expectedAmount, _amount, 1);
            //
        } else if (amount < _expectedAmount) {
            // CASE: Received less than expected
            uint120 _deficit = _expectedAmount - amount;

            // Update global target w/ the deficit then correct the unstaking journal entry
            validatorPendingPtr.pendingUnstaking -= _deficit;

            // Global accounting entries:
            // Implied currentAssets -= _deficit; // -Asset Cr _deficit
            // Implied equity -= _deficit // -Equity Dr _deficit
            //
            // Emit event
            emit UnexpectedDeficitOnUnstakeSettle(_expectedAmount, _amount, 1);
        }

        // Assign the unstaking funds to the 'reservedAssets' account if it does not
        // currently have enough to cover the liabilities
        uint256 _reservedAssets = s_globalCapital.reservedAmount;
        uint256 _currentLiabilities = s_globalLiabilities.currentLiabilities();
        if (_currentLiabilities > _reservedAssets) {
            uint256 _shortfall = _currentLiabilities - _reservedAssets;
            if (_shortfall > _amount) {
                s_globalCapital.reservedAmount += amount; // +Asset Dr amount
                    // Implied: currentAssets -= amount; // -Asset Cr amount
            } else {
                s_globalCapital.reservedAmount += _shortfall.toUint128(); // +Asset Dr _shortfall
                    // Implied: currentAssets -= _shortfall // -Asset Cr _shortfall

                // Queue the remainder to be staked
                globalCashFlowsPtr_N(0).queueToStake += (_amount - _shortfall).toUint120();
            }
        } else {
            // Queue the amount to be staked
            globalCashFlowsPtr_N(0).queueToStake += amount;
        }
    }

    /// @notice Handles accounting of earned (realized and received) staking yield for a validator
    /// @param valId The validator's ID
    /// @param amount The earned yield amount
    function _handleEarnedStakingYield(uint64 valId, uint120 amount) internal {
        // Implied currentAssets += _surplus; // +Asset Dr amount
        // Implied equity += _surplus // +Equity Cr amount

        uint256 _stakingCommissionRate = s_admin.stakingCommission;
        uint120 _grossStakingCommission;
        if (_stakingCommissionRate > 0) {
            _grossStakingCommission = (amount * _stakingCommissionRate / BPS_SCALE).toUint120();
            s_admin.commissionPayable += _grossStakingCommission; // +Liability Cr _grossStakingCommission
            // Implied currentAssets += _grossStakingCommission // +Asset Dr _grossStakingCommission

            amount -= _grossStakingCommission;
        }
        // Validator MON -> ShMonad
        validatorRewardsPtr_N(0, valId).earnedRevenue += amount;

        // Validator is being cranked.
        globalRewardsPtr_N(0).earnedRevenue += amount;

        // Queue the rewards to be staked
        globalCashFlowsPtr_N(0).queueToStake += (amount + _grossStakingCommission);
    }

    /// @notice Handles accounting of successful payment / transfer of escrowed MEV rewards to a validator
    /// @param amount The amount successfully paid
    function _handleRewardsPaidSuccess(uint128 amount) internal {
        // ShMonad MON -> Validator
        s_globalCapital.reservedAmount -= amount; // -Asset Cr amount
        s_globalLiabilities.rewardsPayable -= amount; // -Liability Dr amount
    }

    /// @notice Handles accounting of failed payment / transfer of escrowed MEV rewards to a validator
    /// @param valId The validator's ID
    /// @param amount The amount that failed to be paid
    function _handleRewardsPaidFail(uint64 valId, uint120 amount) internal {
        // ShMonad MON -> Validator
        // Shift epoch from last to current
        validatorRewardsPtr_N(-1, valId).rewardsPayable -= amount;
        validatorRewardsPtr_N(0, valId).rewardsPayable += amount;
    }

    /// @notice Handles accounting of rewards redirection when validator payment fails due to ineligibility
    /// @param amount The amount to redirect
    function _handleRewardsRedirect(uint120 amount) internal {
        // ShMonad MON -> ShMonad MON
        // Remove it as rewards / reserved amount and queue it to stake
        s_globalCapital.reservedAmount -= amount; // -Asset Cr amount
        s_globalLiabilities.rewardsPayable -= amount; // -Liability Dr amount

        globalCashFlowsPtr_N(0).queueToStake += amount;
    }

    /// @notice Reconciles atomic pool allocation/utilization with current state during global crank.
    /// @dev Preserves utilization continuity across cranks by proportionally adjusting `distributedAmount`
    /// and `allocatedAmount` to the new target, then books their effects into stake/unstake queues.
    /// ORDERING: Must run before goodwill application and queue clamping.
    function _settleGlobalNetMONAgainstAtomicUnstaking() internal {
        // Called during the Global crank
        // Get the current utilization rate - we want to make sure the utilization doesn't jump due to being cranked
        (uint128 _oldUtilizedAmount, uint128 _oldAllocatedAmount) = _getAdjustedAmountsForAtomicUnstaking();

        // Handle any overflow that may have been created by updating the targetLiquidityPercent to a smaller
        // percentage of total and potentially overflowing the atomic liquidity pool. Get the new allocated and
        // utilized amounts
        (, uint128 _newAllocatedAmount) = _checkSetNewAtomicLiquidityTarget(_oldAllocatedAmount);

        // Calculate the utilized numbers. Avoid div by zero
        // Keep utilization ratio constant relative to allocation size.
        uint256 _utilizedFraction =
            _oldAllocatedAmount > 0 ? _scaledPercentFromAmounts(_oldUtilizedAmount, _oldAllocatedAmount) : 0;
        uint128 _newUtilizedAmount = _amountFromScaledPercent(_newAllocatedAmount, _utilizedFraction).toUint128();

        // Calculate the deltas
        uint120 _allocatedAmountDelta = Math.dist(_oldAllocatedAmount, _newAllocatedAmount).toUint120();
        uint120 _utilizedAmountDelta = Math.dist(_oldUtilizedAmount, _newUtilizedAmount).toUint120();

        // NOTE: This occurs during the global crank right before the shift of globalCashFlowsPtr_N(0) ->
        // globalCashFlowsPtr_N(-1). Track the adjustments we need to make to the amount being staked.
        uint120 _debitsToQueue;
        uint120 _creditsToQueue;

        if (_newAllocatedAmount > _oldAllocatedAmount) {
            // CASE: We are increasing the atomic unstaking pool's liquidity and therefore decreasing the amount
            // that will be staked next epoch.
            _creditsToQueue += _allocatedAmountDelta;
            s_atomicAssets.allocatedAmount += _allocatedAmountDelta;
            // Implied: currentAssets -= _allocatedAmountDelta;
        } else {
            // CASE: We are decreasing the atomic unstaking pool's liquidity and therefore increasing the amount
            // that will be staked next epoch.
            _debitsToQueue += _allocatedAmountDelta;
            s_atomicAssets.allocatedAmount -= _allocatedAmountDelta; // -Asset Cr _allocatedAmountDelta
                // Implied: currentAssets += _allocatedAmountDelta; // +Asset Dr _allocatedAmountDelta
        }

        // Avoid overflow / underflow - we can't assume that allocatedAmountDelta and utilizedAmountDelta
        // are moving in the same direction
        if (_newUtilizedAmount > _oldUtilizedAmount) {
            _debitsToQueue += _utilizedAmountDelta;
            s_atomicAssets.distributedAmount += _utilizedAmountDelta; // Contra Asset Cr +_utilizedAmountDelta
                // Implied: currentAssets += _utilizedAmountDelta; // +Asset Dr _utilizedAmountDelta
        } else {
            _creditsToQueue += _utilizedAmountDelta;
            s_atomicAssets.distributedAmount -= _utilizedAmountDelta; // -Contra_Asset Dr _utilizedAmountDelta
                // Implied: currentAssets -= _utilizedAmountDelta; // -Asset Cr _utilizedAmountDelta
        }

        // Apply the adjustments to the assets that will be staked next epoch
        // NOTE: we try to offset debits against credits and vice versa when possible because
        // this will reduce the net turnover and therefore the amount of 'unproductive' assets
        CashFlows memory _globalCashFlows = globalCashFlowsPtr_N(0);

        uint120 _debitOffset =
            _debitsToQueue > _globalCashFlows.queueForUnstake ? _globalCashFlows.queueForUnstake : _debitsToQueue;
        _globalCashFlows.queueForUnstake -= _debitOffset;
        _debitsToQueue -= _debitOffset;
        _globalCashFlows.queueToStake += _debitsToQueue;

        uint120 _creditOffset =
            _creditsToQueue > _globalCashFlows.queueToStake ? _globalCashFlows.queueToStake : _creditsToQueue;
        _globalCashFlows.queueToStake -= _creditOffset;
        _creditsToQueue -= _creditOffset;
        _globalCashFlows.queueForUnstake += _creditsToQueue;

        _setStakingQueueStorage(globalCashFlowsPtr_N(0), _globalCashFlows);
    }

    function _queueNetDepositsForStaking(uint256 amount) internal {
        // NOTE: Liabilities has already been increased by the amount of the redemption
        uint256 _currentLiabilities = s_globalLiabilities.currentLiabilities();
        uint256 _reserves = s_globalCapital.reservedAmount;
        uint256 _pendingUnstaking = s_globalPending.pendingUnstaking;
        // NOTE: All MON received from pendingUnstaking is first checked against uncovered current liabilities before
        // being
        // put in the staking queue.

        // Increase reserves to cover any outstanding liabilities
        if (_reserves + _pendingUnstaking < _currentLiabilities) {
            uint256 _uncoveredLiabilities = _currentLiabilities - _reserves - _pendingUnstaking;

            if (amount > _uncoveredLiabilities) {
                s_globalCapital.reservedAmount += _uncoveredLiabilities.toUint120(); // +asset Dr _uncoveredLiabilities;
                // implied currentAssets -= _uncoveredLiabilities // -asset Cr _uncoveredLiabilities;
                amount -= _uncoveredLiabilities;
            } else {
                s_globalCapital.reservedAmount += amount.toUint120(); // +asset Dr amount;
                // implied currentAssets -= amount // -asset Cr amount;
                amount = 0;
            }
        }

        if (amount > 0) globalCashFlowsPtr_N(0).queueToStake += amount.toUint120();
    }

    // ================================================== //
    // Accounting Handlers - User Withdrawals + Deposits  //
    // ================================================== //

    /// @notice Handles accounting for user withdrawals from atomic unstaking pool
    /// @param netAmount The withdrawal amount (net of fee)
    /// @param fee The fee amount
    function _accountForWithdraw(uint256 netAmount, uint256 fee) internal override {
        uint256 _allocatedAmount = s_atomicAssets.allocatedAmount;
        uint256 _distributedAmount = s_atomicAssets.distributedAmount;

        // Avoid SLOAD'ing the globalRewardsPtr_N(0) unless necessary. We aren't finding fee here.
        // NOTE: In most cases the slot is already hot because of _getAdjustedAmountsForAtomicUnstaking()
        if (_distributedAmount + netAmount > _allocatedAmount) {
            uint256 _earnedRevenueOffset = globalRewardsPtr_N(0).earnedRevenue;

            if (_distributedAmount + netAmount > _allocatedAmount + _earnedRevenueOffset) {
                revert InsufficientBalanceAtomicUnstakingPool(netAmount + fee, _allocatedAmount - _distributedAmount);
            }

            // Offset directly with a credit entry, initiating the unstaking process
            uint256 _shortfallAmount = _distributedAmount + netAmount - _allocatedAmount;
            globalCashFlowsPtr_N(0).queueForUnstake += _shortfallAmount.toUint120();

            // Global Accounting entries
            s_atomicAssets.allocatedAmount += _shortfallAmount.toUint120(); // +Asset Dr _shortfallAmount
                // Implied: currentAssets -= _shortfallAmount -Asset Cr _shortfallAmount
        }

        s_atomicAssets.distributedAmount += netAmount.toUint128();
    }

    /// @notice Handles accounting for user deposits
    /// @param assets The deposit amount
    function _accountForDeposit(uint256 assets) internal virtual override {
        // Queue up the necessary staking cranks with the debit entry
        globalCashFlowsPtr_N(0).queueToStake += assets.toUint120();

        // Implied: currentAssets += assets; // +Asset Dr assets
        // Implied: equity += assets; // +Equity Cr assets
    }

    /// @notice Handles accounting after unstake request is made
    /// @param amount The unstake request amount
    function _afterRequestUnstake(uint256 amount) internal virtual override {
        // Queue up the recording unstaking activity, if necessary
        uint120 _amount = amount.toUint120();
        s_globalLiabilities.redemptionsPayable += _amount; // +Liability Cr amount
            // Implied: equity -= amount; // -Equity Dr amount

        globalCashFlowsPtr_N(0).queueForUnstake += amount.toUint120();
    }

    /// @notice Handles accounting of completion of unstake request
    /// @param amount The unstake completion amount
    function _beforeCompleteUnstake(uint128 amount) internal virtual override {
        uint128 reservedAmount = s_globalCapital.reservedAmount;
        if (reservedAmount < amount) {
            revert InsufficientReservedLiquidity(amount, reservedAmount);
        }

        s_globalCapital.reservedAmount -= amount; // -Asset Cr amount
        s_globalLiabilities.redemptionsPayable -= amount; // -Liability Dr amount
    }

    // ================================================== //
    //                        Math                        //
    // ================================================== //

    /// @notice Returns atomic pool utilization/allocation adjusted for pending revenue settlement.
    /// @dev Offsets `distributedAmount` by min(currentRevenue, distributed) so fee math doesn't jump at crank.
    /// @return utilizedAmount Adjusted utilized (distributed) amount.
    /// @return allocatedAmount Current allocated amount (unchanged).
    function _getAdjustedAmountsForAtomicUnstaking()
        internal
        view
        returns (uint128 utilizedAmount, uint128 allocatedAmount)
    {
        // Get the initial total amount
        AtomicCapital memory _atomicAssets = s_atomicAssets;
        allocatedAmount = _atomicAssets.allocatedAmount;
        utilizedAmount = _atomicAssets.distributedAmount;

        // If this occurs during the global crank, globalRewardsPtr_N(0) is the epoch that just ended.
        // Otherwise, globalRewardsPtr_N(0) is the ongoing epoch.
        uint128 _currentRevenue = globalRewardsPtr_N(0).earnedRevenue;

        // The _shiftAtomicPoolValuesDuringCrank() method will only settle a max amount of
        // globalRewardsPtr_N(0).earnedRevenue during the global crank. This means that we can offset that
        // future-settled amount here and avoid any sharp adjustments to the fee whenever we crank
        utilizedAmount -= Math.min(_currentRevenue, utilizedAmount).toUint128();

        return (utilizedAmount, allocatedAmount);
    }

    /// @notice Returns available liquidity and total allocation for atomic unstaking pool.
    /// @dev Mirrors `_getAdjustedAmountsForAtomicUnstaking` adjustment to avoid fee discontinuity in previews.
    /// @return currentAvailableAmount Currently withdrawable amount (allocated - adjusted utilized).
    /// @return totalAllocatedAmount Total allocated (float target) for atomic pool.
    function _getLiquidityForAtomicUnstaking()
        internal
        view
        returns (uint256 currentAvailableAmount, uint256 totalAllocatedAmount)
    {
        // Get the initial total amount
        AtomicCapital memory _atomicAssets = s_atomicAssets;
        totalAllocatedAmount = uint256(_atomicAssets.allocatedAmount);
        uint256 _utilizedAmount = uint256(_atomicAssets.distributedAmount);

        uint256 _currentRevenue = uint256(globalRewardsPtr_N(0).earnedRevenue);

        // The _shiftAtomicPoolValuesDuringCrank() method will only settle a max amount of
        // globalRewardsPtr_N(0).earnedRevenue during the global crank, which also resets
        // globalRewardsPtr_N(0).earnedRevenue to zero. This means that we can offset that
        // future-settled amount here and avoid any sharp adjustments to the fee whenever we crank
        _utilizedAmount -= Math.min(_currentRevenue, _utilizedAmount).toUint128();

        currentAvailableAmount = totalAllocatedAmount - _utilizedAmount;

        return (currentAvailableAmount, totalAllocatedAmount);
    }

    // ================================================== //
    //                    Percent Math                   //
    // ================================================== //
    /// @notice Gets target liquidity percentage scaled to `SCALE` (1e18).
    /// @dev Converts `s_admin.targetLiquidityPercentage` (BPS) → scaled (1e18).
    /// @return Scaled target percentage in 1e18 units.
    function _scaledTargetLiquidityPercentage() internal view returns (uint256) {
        return s_admin.targetLiquidityPercentage * SCALE / BPS_SCALE;
    }

    /// @notice Converts scaled (1e18) target liquidity percentage to unscaled BPS.
    /// @param scaledTargetLiquidityPercentage Target liquidity percentage in 1e18 units.
    /// @return Unscaled percentage in BPS.
    function _unscaledTargetLiquidityPercentage(uint256 scaledTargetLiquidityPercentage)
        internal
        pure
        returns (uint16)
    {
        return (scaledTargetLiquidityPercentage * BPS_SCALE / SCALE).toUint16();
    }

    /// @notice Computes a scaled percentage from two unscaled amounts.
    /// @dev Returns `numerator * SCALE / denominator`. Caller must ensure `denominator > 0`.
    /// @param unscaledNumeratorAmount Numerator amount (unscaled).
    /// @param unscaledDenominatorAmount Denominator amount (unscaled, must be > 0).
    /// @return Scaled percentage in 1e18 units.
    function _scaledPercentFromAmounts(
        uint256 unscaledNumeratorAmount,
        uint256 unscaledDenominatorAmount
    )
        internal
        pure
        returns (uint256)
    {
        return unscaledNumeratorAmount * SCALE / unscaledDenominatorAmount;
    }

    /// @notice Applies a scaled percentage to a gross amount.
    /// @dev Returns `grossAmount * scaledPercent / SCALE`.
    /// @param grossAmount Gross (unscaled) amount.
    /// @param scaledPercent Percentage in 1e18 units.
    /// @return Resulting unscaled amount after applying percentage.
    function _amountFromScaledPercent(uint256 grossAmount, uint256 scaledPercent) internal pure returns (uint256) {
        return grossAmount * scaledPercent / SCALE;
    }

    // --------------------------------------------- //
    //                  View Functions               //
    // --------------------------------------------- //

    /// @notice Returns true if global crank can run based on basic readiness checks.
    /// @dev Ready when: contract not frozen, all validators cranked, and new epoch available. This is essentially a
    /// view function but cannot be declared as such because the Monad staking precompile absolutely hates when we call
    /// its function calls view or staticcall.
    function isGlobalCrankAvailable() external returns (bool) {
        if (globalEpochPtr_N(0).frozen) return false;

        return s_nextValidatorToCrank == LAST_VAL_ADDRESS && globalEpochPtr_N(0).epoch < _getEpoch();
    }

    /// @notice Returns true if a specific validator can be cranked based on basic checks.
    /// @dev Ready when: contract not frozen, coinbase is a valid registered validator, and last epoch not cranked.
    function isValidatorCrankAvailable(uint64 validatorId) external view returns (bool) {
        if (globalEpochPtr_N(0).frozen) return false;
        if (validatorId == 0 || validatorId == UNKNOWN_VAL_ID) return false;
        address _coinbase = _validatorCoinbase(validatorId);
        if (_coinbase == address(0) || _coinbase == FIRST_VAL_ADDRESS || _coinbase == LAST_VAL_ADDRESS) return false;
        return !validatorEpochPtr_N(-1, validatorId).wasCranked;
    }

    /// @notice Returns current working capital snapshot (no structs).
    /// @return stakedAmount Total staked amount
    /// @return reservedAmount Total reserved amount
    function getWorkingCapital() external view returns (uint128 stakedAmount, uint128 reservedAmount) {
        WorkingCapital memory _workingCapital = s_globalCapital;
        return (_workingCapital.stakedAmount, _workingCapital.reservedAmount);
    }

    /// @notice Returns atomic capital snapshot (no structs).
    /// @return allocatedAmount Total allocated amount for atomic pool
    /// @return distributedAmount Amount already distributed to atomic unstakers
    function getAtomicCapital() external view returns (uint128 allocatedAmount, uint128 distributedAmount) {
        AtomicCapital memory _atomicCapital = s_atomicAssets;
        return (_atomicCapital.allocatedAmount, _atomicCapital.distributedAmount);
    }

    /// @notice Returns global pending escrow snapshot (no structs).
    /// @return pendingStaking Pending staking amount
    /// @return pendingUnstaking Pending unstaking amount
    function getGlobalPending() external view returns (uint120 pendingStaking, uint120 pendingUnstaking) {
        StakingEscrow memory _stakingEscrow = s_globalPending;
        return (_stakingEscrow.pendingStaking, _stakingEscrow.pendingUnstaking);
    }

    /// @notice Returns selected epoch global cash flows (no structs).
    /// @param epochPointer Epoch selector: -2=LastLast, -1=Last, 0=Current, 1=Next (others wrap modulo tracking)
    /// @return queueToStake Queue to stake for selected epoch
    /// @return queueForUnstake Queue for unstake for selected epoch
    function getGlobalCashFlowsCurrent(int256 epochPointer)
        external
        view
        returns (uint120 queueToStake, uint120 queueForUnstake)
    {
        CashFlows memory _cashFlows = globalCashFlowsPtr_N(epochPointer);
        return (_cashFlows.queueToStake, _cashFlows.queueForUnstake);
    }

    /// @notice Returns selected epoch global rewards (no structs).
    /// @param epochPointer Epoch selector: -2=LastLast, -1=Last, 0=Current, 1=Next (others wrap modulo tracking)
    /// @return rewardsPayable Rewards payable for selected epoch
    /// @return earnedRevenue Earned revenue for selected epoch
    function getGlobalRewardsCurrent(int256 epochPointer)
        external
        view
        returns (uint120 rewardsPayable, uint120 earnedRevenue)
    {
        PendingBoost memory _pendingBoost = globalRewardsPtr_N(epochPointer);
        return (_pendingBoost.rewardsPayable, _pendingBoost.earnedRevenue);
    }

    /// @notice Returns selected global epoch data (no structs).
    /// @param epochPointer Epoch selector: -2=LastLast, -1=Last, 0=Current, 1=Next (others wrap modulo tracking)
    function getGlobalEpochCurrent(int256 epochPointer)
        external
        view
        returns (
            uint64 epoch,
            uint8 withdrawalId,
            bool hasWithdrawal,
            bool hasDeposit,
            bool crankedInBoundaryPeriod,
            bool wasCranked,
            bool frozen,
            bool closed,
            uint128 targetStakeAmount
        )
    {
        Epoch memory _epoch = globalEpochPtr_N(epochPointer);
        return (
            _epoch.epoch,
            _epoch.withdrawalId,
            _epoch.hasWithdrawal,
            _epoch.hasDeposit,
            _epoch.crankedInBoundaryPeriod,
            _epoch.wasCranked,
            _epoch.frozen,
            _epoch.closed,
            _epoch.targetStakeAmount
        );
    }

    /// @notice Returns internal epoch counter used by StakeTracker.
    function getInternalEpoch() external view returns (uint64) {
        return s_admin.internalEpoch;
    }

    /// @notice Returns selected epoch frozen/closed status convenience flags.
    /// @param epochPointer Epoch selector: -2=LastLast, -1=Last, 0=Current, 1=Next (others wrap modulo tracking)
    function getGlobalStatus(int256 epochPointer) external view returns (bool frozen, bool closed) {
        Epoch memory _epoch = globalEpochPtr_N(epochPointer);
        return (_epoch.frozen, _epoch.closed);
    }

    /// @notice Returns the current target liquidity percentage scaled to 1e18.
    function getScaledTargetLiquidityPercentage() external view returns (uint256) {
        return _scaledTargetLiquidityPercentage();
    }

    /// @notice Returns the global amount currently eligible to be unstaked.
    function getGlobalAmountAvailableToUnstake() external view returns (uint256 amount) {
        return StakeAllocationLib.getGlobalAmountAvailableToUnstake(s_globalCapital, s_globalPending);
    }

    /// @notice Returns current-assets per AccountingLib.
    function getCurrentAssets() external view returns (uint256) {
        return s_globalCapital.currentAssets(s_atomicAssets, address(this).balance);
    }

    /// @notice View wrapper for the next target stake calculation.
    function computeNextTargetStakeAmount() external view returns (uint128) {
        return _computeNextTargetStakeAmount();
    }

    // ================================================== //
    //                 Overriding Methods                 //
    // ================================================== //
    /// @notice Returns the Monad staking precompile interface
    /// @return IMonadStaking The staking precompile interface
    function STAKING_PRECOMPILE() public pure override returns (IMonadStaking) {
        return STAKING;
    }

    /// @notice Modifier that sets up transient capital for unstaking settlement
    modifier expectsUnstakingSettlement() override {
        _setTransientCapital(CashFlowType.AllocationReduction, 0);
        _;
        _clearTransientCapital();
    }

    /// @notice Modifier that sets up transient capital for rewards settlement
    modifier expectsStakingRewards() override {
        _setTransientCapital(CashFlowType.Revenue, 0);
        _;
        _clearTransientCapital();
    }
}
