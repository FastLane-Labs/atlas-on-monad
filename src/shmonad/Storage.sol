//SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.8.28 <0.9.0;

import { ShMonadErrors } from "./Errors.sol";
import { ShMonadEvents } from "./Events.sol";
import {
    Balance,
    Policy,
    CommittedData,
    UncommittingData,
    TopUpData,
    TopUpSettings,
    Supply,
    UserUnstakeRequest,
    UncommitApproval,
    Epoch,
    PendingBoost,
    CashFlows,
    StakingEscrow,
    AtomicCapital,
    AdminValues,
    ValidatorData,
    ValidatorDataStorage,
    FeeParams,
    WorkingCapital,
    CurrentLiabilities,
    RevenueSmoother
} from "./Types.sol";
import { IShMonad } from "./interfaces/IShMonad.sol";
import { STAKING, EPOCHS_TRACKED, WITHDRAWAL_DELAY } from "./Constants.sol";

abstract contract ShMonadStorage is ShMonadErrors, ShMonadEvents, IShMonad {
    uint40 internal immutable STAKING_WITHDRAWAL_DELAY; // Measured in Monad staking epochs

    uint64 internal s_policyCount = 0; // Incremented to create ID for each new policy.

    // ERC20 data
    uint256 internal s_totalSupply; // UNUSED - maintained for storage layout compatibility
    uint256 internal s_committedTotalSupply; // UNUSED - maintained for storage layout compatibility
    mapping(address account => Balance balance) internal s_balances; // Tracks all types and committed balances
    mapping(address account => mapping(address spender => uint256)) internal s_allowances;

    // Policy-Account Committed, Uncommitting, and Top-Up data
    mapping(uint64 policyID => mapping(address account => CommittedData committedData)) internal s_committedData;
    mapping(uint64 policyID => mapping(address account => UncommittingData uncommittingData)) internal
        s_uncommittingData;
    mapping(uint64 policyID => mapping(address account => TopUpData topUpData)) internal s_topUpData;
    mapping(uint64 policyID => mapping(address account => TopUpSettings topUpSettings)) internal s_topUpSettings;

    // Policy data
    mapping(uint64 policyID => Policy policy) internal s_policies;
    mapping(uint64 policyID => mapping(address agent => bool)) internal s_isPolicyAgent;
    mapping(uint64 policyID => address[] policyAgents) internal s_policyAgents;

    // NOTE: `initialize()` for Ownable setup defined in ShMonad.sol

    // Added in 1.2
    // Unused - replaced by s_uncommitApprovals
    mapping(address task => bytes32 policyIdUserHash) internal s_userTaskUncommits;

    // Added in 1.3
    // NOTE: Move this to replace s_totalSupply / committed in prod, but keep as separate storage
    // on testnet to prevent disrupting balances.
    Supply internal s_supply;

    // Added in 2.0

    // Pending validator unstake requests
    mapping(address requestor => UserUnstakeRequest) internal s_unstakeRequests;

    // Validator Management
    mapping(uint64 validatorId => bool) internal s_validatorIsActive;

    // Policies
    mapping(uint64 policyID => mapping(address account => UncommitApproval uncommitApproval)) internal
        s_uncommitApprovals;

    // --------------------------------------------- //
    // StakeTracker State Start
    // --------------------------------------------- //

    FeeParams internal s_feeParams;
    AdminValues internal s_admin;

    WorkingCapital internal s_globalCapital;
    StakingEscrow internal s_globalPending;
    CurrentLiabilities internal s_globalLiabilities;
    AtomicCapital internal s_atomicAssets;
    RevenueSmoother internal s_revenueSmoother;

    CashFlows[EPOCHS_TRACKED] internal s_globalCashFlows;
    Epoch[EPOCHS_TRACKED] internal s_globalEpoch;
    PendingBoost[EPOCHS_TRACKED] internal s_globalRewards;

    mapping(uint64 valId => Epoch[EPOCHS_TRACKED]) internal s_validatorEpoch;
    mapping(uint64 valId => PendingBoost[EPOCHS_TRACKED]) internal s_validatorRewards;
    mapping(uint64 valId => StakingEscrow[EPOCHS_TRACKED]) internal s_validatorPending;

    mapping(uint64 valId => ValidatorDataStorage validatorData) internal s_validatorData;
    mapping(uint64 valId => address coinbase) internal s_valCoinbases;
    mapping(address coinbase => uint64 valId) internal s_valIdByCoinbase;
    mapping(uint64 valId => uint64 internalEpoch) internal s_valEligibility;
    mapping(address thisValidator => address nextValidator) internal s_valLinkNext;
    mapping(address thisValidator => address previousValidator) internal s_valLinkPrevious;

    uint256 internal s_activeValidatorCount;
    uint256 internal s_pendingTargetAtomicLiquidityPercent;
    address internal s_nextValidatorToCrank;
    uint256 internal transient t_cashFlowClassifier;

    // --------------------------------------------- //
    // StakeTracker State End
    // --------------------------------------------- //

    constructor() {
        STAKING_WITHDRAWAL_DELAY = uint40(WITHDRAWAL_DELAY);
    }

    // --------------------------------------------- //
    //                  View Functions               //
    // --------------------------------------------- //

    function policyCount() external view returns (uint64) {
        return s_policyCount;
    }

    function getPolicy(uint64 policyID) external view returns (Policy memory) {
        return s_policies[policyID];
    }

    function isPolicyAgent(uint64 policyID, address agent) external view returns (bool) {
        return _isPolicyAgent(policyID, agent);
    }

    function getPolicyAgents(uint64 policyID) external view returns (address[] memory) {
        return s_policyAgents[policyID];
    }

    function globalLiabilities()
        external
        view
        returns (uint128 rewardsPayable, uint128 redemptionsPayable, uint128 commissionPayable)
    {
        CurrentLiabilities memory _liabilities = s_globalLiabilities;
        AdminValues memory _admin = s_admin;
        rewardsPayable = _liabilities.rewardsPayable;
        redemptionsPayable = _liabilities.redemptionsPayable;
        commissionPayable = _admin.commissionPayable;
    }

    // --------------------------------------------- //
    //                  View Functions               //
    // --------------------------------------------- //

    /// @notice Returns a user's pending unstake request data (no structs).
    function getUnstakeRequest(address account) external view returns (uint128 amountMon, uint64 completionEpoch) {
        UserUnstakeRequest memory _userUnstakeReq = s_unstakeRequests[account];
        return (_userUnstakeReq.amountMon, _userUnstakeReq.completionEpoch);
    }

    /// @notice Returns admin values (no structs).
    function getAdminValues()
        external
        view
        returns (
            uint64 internalEpoch,
            uint16 targetLiquidityPercentage,
            uint16 incentiveAlignmentPercentage,
            uint16 stakingCommission,
            uint16 boostCommissionRate,
            uint128 commissionPayable
        )
    {
        AdminValues memory _admin = s_admin;
        return (
            _admin.internalEpoch,
            _admin.targetLiquidityPercentage,
            _admin.incentiveAlignmentPercentage,
            _admin.stakingCommission,
            _admin.boostCommissionRate,
            _admin.commissionPayable
        );
    }

    // ================================================== //
    //                 Epoch Alignment                    //
    // ================================================== //

    function N(int256 nDelta) internal view returns (uint256 index) {
        int256 _internalEpoch = int256(uint256(s_admin.internalEpoch));
        unchecked {
            // Allow underflow
            index = uint256(_internalEpoch + nDelta) % EPOCHS_TRACKED;
        }
    }

    function globalCashFlowsPtr_N(int256 nDelta) internal view returns (CashFlows storage ptr) {
        ptr = s_globalCashFlows[N(nDelta)];
    }

    function globalEpochPtr_N(int256 nDelta) internal view returns (Epoch storage ptr) {
        ptr = s_globalEpoch[N(nDelta)];
    }

    function globalRewardsPtr_N(int256 nDelta) internal view returns (PendingBoost storage ptr) {
        ptr = s_globalRewards[N(nDelta)];
    }

    function validatorEpochPtr_N(int256 nDelta, uint64 valId) internal view returns (Epoch storage ptr) {
        ptr = s_validatorEpoch[valId][N(nDelta)];
    }

    function validatorRewardsPtr_N(int256 nDelta, uint64 valId) internal view returns (PendingBoost storage ptr) {
        ptr = s_validatorRewards[valId][N(nDelta)];
    }

    function validatorPendingPtr_N(int256 nDelta, uint64 valId) internal view returns (StakingEscrow storage ptr) {
        ptr = s_validatorPending[valId][N(nDelta)];
    }

    // ================================================== //
    //       Avoiding SSTORE over Null Values             //
    // ================================================== //

    function _setEpochStorage(Epoch storage ptr, Epoch memory values) internal {
        ptr.epoch = values.epoch;
        ptr.withdrawalId = values.withdrawalId;
        ptr.hasWithdrawal = values.hasWithdrawal;
        ptr.hasDeposit = values.hasDeposit;
        ptr.crankedInBoundaryPeriod = values.crankedInBoundaryPeriod;
        ptr.wasCranked = values.wasCranked;
        ptr.frozen = values.frozen;
        ptr.closed = values.closed;
        ptr.targetStakeAmount = values.targetStakeAmount;
    }

    function _setStakingQueueStorage(CashFlows storage ptr, CashFlows memory values) internal {
        ptr.queueForUnstake = values.queueForUnstake;
        ptr.queueToStake = values.queueToStake;
    }

    function _setRewardsStorage(PendingBoost storage ptr, PendingBoost memory values) internal {
        ptr.rewardsPayable = values.rewardsPayable;
        ptr.earnedRevenue = values.earnedRevenue;
    }

    function _setPendingStakeStorage(StakingEscrow storage ptr, StakingEscrow memory values) internal {
        ptr.pendingStaking = values.pendingStaking;
        ptr.pendingUnstaking = values.pendingUnstaking;
    }

    // --------------------------------------------- //
    //                Internal Functions             //
    // --------------------------------------------- //

    function _isPolicyAgent(uint64 policyID, address agent) internal view returns (bool) {
        return s_isPolicyAgent[policyID][agent];
    }

    // --------------------------------------------- //
    //                    Modifiers                  //
    // --------------------------------------------- //
    modifier notWhenFrozen() {
        if (globalEpochPtr_N(0).frozen) {
            revert NotWhenFrozen();
        }
        _;
    }

    modifier notWhenClosed() {
        if (globalEpochPtr_N(0).closed) {
            revert NotWhenClosed();
        }
        _;
    }
}
