// //SPDX-License-Identifier: BUSL-1.1
// pragma solidity >=0.8.28 <0.9.0;

// import { FastLaneERC4626 } from "../FLERC4626.sol";
// import {
//     Epoch,
//     PendingBoost,
//     CashFlows,
//     UserUnstakeRequest,
//     ValidatorStats,
//     StakingEscrow,
//     AtomicCapital,
//     ValidatorData,
//     ValidatorDataStorage,
//     WorkingCapital,
//     CashFlowType,
//     CurrentLiabilities,
//     AdminValues
// } from "../Types.sol";
// import { StakeAllocationLib } from "../libraries/StakeAllocationLib.sol";
// import { StorageLib } from "../libraries/StorageLib.sol";
// import { AccountingLib } from "../libraries/AccountingLib.sol";

// abstract contract TestnetHarness is FastLaneERC4626 {
//     using AccountingLib for WorkingCapital;
//     using AccountingLib for AtomicCapital;
//     using AccountingLib for CurrentLiabilities;
//     using StorageLib for CashFlows;
//     using StorageLib for StakingEscrow;
//     using StorageLib for PendingBoost;

//     event LogContext(
//         uint64 internalEpoch,
//         uint64 monadEpoch,
//         bool inBoundaryPeriod,
//         uint256 blockNumber,
//         uint256 msgValue,
//         address msgSender
//     );
//     event LogAssetDeltas(int256 totalStaked, int256 totalAtomic, int256 totalReserved, int256 totalCurrent);
//     event LogEquityLiabilityDeltas(
//         int256 equity, int256 rewardsPayable, int256 redemptionsPayable, int256 commissionPayable
//     );
//     event LogFlowDeltas(
//         bool balanced,
//         int256 queueToStake,
//         int256 queueForUnstake,
//         int256 pendingStaking,
//         int256 pendingUnstaking,
//         int256 earnedRevenue,
//         int256 addressThisBalance
//     );
//     event UnexpectedMissingValues(int256 assetDelta, int256 equityLiabilityDelta, int256 missingAmount);

//     // Assets
//     uint256 transient t_stakedAssets;
//     uint256 transient t_atomicAssets;
//     uint256 transient t_reservedAssets;
//     uint256 transient t_currentAssets;
//     // Equity + Liabilities
//     uint256 transient t_equity;
//     uint256 transient t_rewardsPayable;
//     uint256 transient t_redemptionsPayable;
//     uint256 transient t_commissionPayable;

//     // Flows
//     uint256 transient t_msgValue;
//     uint256 transient t_addressThisBalance;
//     uint256 transient t_queueToStake;
//     uint256 transient t_queueForUnstake;
//     uint256 transient t_pendingStaking;
//     uint256 transient t_pendingUnstaking;
//     uint256 transient t_earnedRevenue;

//     // Misc
//     address transient t_msgSender;

//     //
//     modifier EmitLogs() override {
//         _setAccountingValues();
//         _;
//         _logDeltas();
//         _clearAccountingValues();
//     }

//     function _setAccountingValues() internal {
//         {
//             WorkingCapital memory _globalCapital = s_globalCapital;
//             AtomicCapital memory _atomicCapital = s_atomicAssets;

//             t_stakedAssets = _globalCapital.stakedAmount;
//             t_reservedAssets = _globalCapital.reservedAmount;
//             t_atomicAssets = _atomicCapital.allocatedAmount - _atomicCapital.distributedAmount;
//             t_currentAssets = _globalCapital.currentAssets(_atomicCapital, address(this).balance - msg.value);

//             CurrentLiabilities memory _globalLiabilities = s_globalLiabilities;
//             t_rewardsPayable = _globalLiabilities.rewardsPayable;
//             t_redemptionsPayable = _globalLiabilities.redemptionsPayable;
//             t_commissionPayable = s_admin.commissionPayable;
//             t_equity = __totalEquity() - msg.value;
//         }
//         {
//             t_msgValue = msg.value;
//             t_addressThisBalance = address(this).balance - msg.value;
//             CashFlows memory _globalCashFlows = globalCashFlowsPtr_N(0);
//             t_queueToStake = _globalCashFlows.queueToStake;
//             t_queueForUnstake = _globalCashFlows.queueForUnstake;
//             StakingEscrow memory _globalPending = s_globalPending;
//             t_pendingStaking = _globalPending.pendingStaking;
//             t_pendingUnstaking = _globalPending.pendingUnstaking;
//             t_earnedRevenue = globalRewardsPtr_N(0).earnedRevenue;
//         }
//         t_msgSender = msg.sender;
//     }

//     function _clearAccountingValues() internal {
//         t_stakedAssets = 0;
//         t_reservedAssets = 0;
//         t_atomicAssets = 0;
//         t_currentAssets = 0;
//         t_rewardsPayable = 0;
//         t_redemptionsPayable = 0;
//         t_commissionPayable = 0;
//         t_equity = 0;
//         t_msgValue = 0;
//         t_addressThisBalance = 0;
//         t_queueToStake = 0;
//         t_queueForUnstake = 0;
//         t_pendingStaking = 0;
//         t_pendingUnstaking = 0;
//         t_earnedRevenue = 0;
//         t_msgSender = address(0);
//     }

//     function _getAssetDeltas()
//         internal
//         returns (int256 totalStaked, int256 totalAtomic, int256 totalReserved, int256 totalCurrent)
//     {
//         WorkingCapital memory _globalCapital = s_globalCapital;
//         AtomicCapital memory _atomicCapital = s_atomicAssets;

//         totalStaked = int256(uint256(_globalCapital.stakedAmount)) - int256(t_stakedAssets);
//         totalAtomic =
//             int256(uint256(_atomicCapital.allocatedAmount - _atomicCapital.distributedAmount)) -
// int256(t_atomicAssets);
//         totalReserved = int256(uint256(_globalCapital.reservedAmount)) - int256(t_reservedAssets);
//         totalCurrent =
//             int256(_globalCapital.currentAssets(_atomicCapital, address(this).balance)) - int256(t_currentAssets);
//     }

//     function _getLiabilityEquityDeltas()
//         internal
//         returns (int256 equity, int256 rewardsPayable, int256 redemptionsPayable, int256 commissionPayable)
//     {
//         CurrentLiabilities memory _globalLiabilities = s_globalLiabilities;
//         rewardsPayable = int256(uint256(_globalLiabilities.rewardsPayable)) - int256(t_rewardsPayable);
//         redemptionsPayable = int256(uint256(_globalLiabilities.redemptionsPayable)) - int256(t_redemptionsPayable);
//         commissionPayable = int256(uint256(s_admin.commissionPayable)) - int256(t_commissionPayable);
//         equity = int256(__totalEquity()) - int256(t_equity);
//     }

//     function _getFlowDeltas()
//         internal
//         returns (
//             int256 queueToStake,
//             int256 queueForUnstake,
//             int256 pendingStaking,
//             int256 pendingUnstaking,
//             int256 earnedRevenue,
//             int256 addressThisBalance
//         )
//     {
//         CashFlows memory _globalCashFlows = globalCashFlowsPtr_N(0);
//         queueToStake = int256(uint256(_globalCashFlows.queueToStake)) - int256(t_queueToStake);
//         queueForUnstake = int256(uint256(_globalCashFlows.queueForUnstake)) - int256(t_queueForUnstake);
//         StakingEscrow memory _globalPending = s_globalPending;
//         pendingStaking = int256(uint256(_globalPending.pendingStaking)) - int256(t_pendingStaking);
//         pendingUnstaking = int256(uint256(_globalPending.pendingUnstaking)) - int256(t_pendingUnstaking);
//         earnedRevenue = int256(uint256(globalRewardsPtr_N(0).earnedRevenue)) - int256(t_earnedRevenue);
//         addressThisBalance = int256(address(this).balance) - int256(t_addressThisBalance);
//     }

//     function _logAndSumAssetDeltas() internal returns (int256 totalAssetDelta) {
//         (int256 totalStaked, int256 totalAtomic, int256 totalReserved, int256 totalCurrent) = _getAssetDeltas();
//         emit LogAssetDeltas(totalStaked, totalAtomic, totalReserved, totalCurrent);
//         totalAssetDelta = totalStaked + totalAtomic + totalReserved + totalCurrent;
//     }

//     function _logAndSumLiabilityEquityDeltas() internal returns (int256 totalLiabilityEquityDelta) {
//         (int256 equity, int256 rewardsPayable, int256 redemptionsPayable, int256 commissionPayable) =
//             _getLiabilityEquityDeltas();
//         emit LogEquityLiabilityDeltas(equity, rewardsPayable, redemptionsPayable, commissionPayable);
//         totalLiabilityEquityDelta = equity + rewardsPayable + redemptionsPayable + commissionPayable;
//     }

//     function _logDeltas() internal {
//         emit LogContext(
//             s_admin.internalEpoch, _getEpoch(), _inEpochDelayPeriod(), block.number, t_msgValue, t_msgSender
//         );
//         int256 totalAssetDelta = _logAndSumAssetDeltas();
//         int256 totalLiabilityEquityDelta = _logAndSumLiabilityEquityDeltas();
//         bool balanced = totalAssetDelta == totalLiabilityEquityDelta;
//         (
//             int256 queueToStake,
//             int256 queueForUnstake,
//             int256 pendingStaking,
//             int256 pendingUnstaking,
//             int256 earnedRevenue,
//             int256 addressThisBalance
//         ) = _getFlowDeltas();
//         emit LogFlowDeltas(
//             balanced, queueToStake, queueForUnstake, pendingStaking, pendingUnstaking, earnedRevenue,
// addressThisBalance
//         );
//         if (!balanced) {
//             emit UnexpectedMissingValues(
//                 totalAssetDelta, totalLiabilityEquityDelta, totalAssetDelta - totalLiabilityEquityDelta
//             );
//         }
//     }

//     function __totalEquity() private view returns (uint256) {
//         WorkingCapital memory _globalCapital = s_globalCapital;
//         return _globalCapital.totalEquity(s_globalLiabilities, s_admin, address(this).balance);
//     }
// }
