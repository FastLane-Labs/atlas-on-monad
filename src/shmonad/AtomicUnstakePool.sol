// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.8.28 <0.9.0;

import { SafeTransferLib } from "@solady/utils/SafeTransferLib.sol";
import { SafeCastLib } from "@solady/utils/SafeCastLib.sol";
import { FixedPointMathLib as Math } from "@solady/utils/FixedPointMathLib.sol";

import { StakeTracker } from "./StakeTracker.sol";
import { FeeParams, AtomicCapital } from "./Types.sol";
import {
    BPS_SCALE, RAY, DEFAULT_Y_INTERCEPT_RAY, DEFAULT_SLOPE_RATE_RAY, FLOAT_PLACEHOLDER, SCALE
} from "./Constants.sol";
import { FeeLib } from "./libraries/FeeLib.sol";

/// @notice See `FeeLib` for the detailed affine-in-utilization fee derivation and solver docs.
abstract contract AtomicUnstakePool is StakeTracker {
    using SafeTransferLib for address;
    using SafeCastLib for uint256;
    using Math for uint256;
    using FeeLib for uint256;

    function __AtomicUnstakePool_init() internal {
        FeeParams memory _feeParams = s_feeParams;

        if (_feeParams.mRay == 0 && _feeParams.cRay == 0) {
            // Initialize to default fee curve if not already set
            _feeParams = FeeParams({ mRay: DEFAULT_SLOPE_RATE_RAY, cRay: DEFAULT_Y_INTERCEPT_RAY });
            s_feeParams = _feeParams;

            emit FeeCurveUpdated(0, 0, _feeParams.mRay, _feeParams.cRay);
        }
    }

    // ================================================== //
    //                 Parameter Management               //
    // ================================================== //

    // Fees are always enabled. To disable fees, set the fee curve to (0, 0)
    // via `setUnstakeFeeCurve(0, 0)`.

    function setPoolTargetLiquidityPercentage(uint256 newPercentageScaled) public virtual onlyOwner {
        require(newPercentageScaled <= SCALE, "CantExceedOneHundredPercent");

        // Pending target liquidity percentages are tracked in 1e18-scaled units.
        s_pendingTargetAtomicLiquidityPercent = newPercentageScaled;
    }

    /// @notice Update fee curve parameters.
    /// @dev The fee curve is defined as y = mx + c, where:
    /// - y is the fee rate in RAY (1e27)
    /// - m is the slopeRateRay (RAY at u=1)
    /// - c is the yInterceptRay (intercept/base fee in RAY)
    /// - x is the pool utilization
    /// @param newSlopeRateRay slope a (RAY at u=1)
    /// @param newYInterceptRay intercept/base fee (RAY)
    function setUnstakeFeeCurve(uint256 newSlopeRateRay, uint256 newYInterceptRay) external onlyOwner {
        require(newYInterceptRay <= RAY, YInterceptExceedsRay());
        require(newSlopeRateRay <= RAY, SlopeRateExceedsRay());
        require(newYInterceptRay + newSlopeRateRay <= RAY, FeeCurveFullUtilizationExceedsRay());

        FeeParams memory _oldParams = s_feeParams;
        s_feeParams = FeeParams({ mRay: uint128(newSlopeRateRay), cRay: uint128(newYInterceptRay) });

        emit FeeCurveUpdated(_oldParams.mRay, _oldParams.cRay, s_feeParams.mRay, s_feeParams.cRay);
    }

    // ================================================== //
    //                  View Functions                    //
    // ================================================== //

    function yInterceptRay() public view returns (uint256) {
        return uint256(s_feeParams.cRay);
    }

    function slopeRateRay() public view returns (uint256) {
        return uint256(s_feeParams.mRay);
    }

    function getCurrentLiquidity() external view returns (uint256) {
        (uint256 _currentAvailableAmount, uint256 _totalAllocatedAmount) = _getLiquidityForAtomicUnstaking();
        // No allocation implies no withdrawable liquidity even if idle balance exists.
        if (_totalAllocatedAmount == 0) return 0;

        return _currentAvailableAmount;
    }

    function getTargetLiquidity() external view returns (uint256) {
        return _getTargetLiquidity();
    }

    function getPendingTargetLiquidity() external view returns (uint256) {
        uint256 _targetLiquidity = _getTargetLiquidity();
        uint256 _newScaledTargetPercent = s_pendingTargetAtomicLiquidityPercent;

        if (_newScaledTargetPercent == FLOAT_PLACEHOLDER) {
            return _targetLiquidity;
        } else {
            uint256 _oldScaledTargetPercent = _scaledTargetLiquidityPercentage();
            if (_oldScaledTargetPercent == 0) return 0;
            return _targetLiquidity * _newScaledTargetPercent / _oldScaledTargetPercent;
        }
    }

    function getFeeCurveParams() external view returns (uint256 slopeRateRayOut, uint256 yInterceptRayOut) {
        slopeRateRayOut = s_feeParams.mRay;
        yInterceptRayOut = s_feeParams.cRay;
    }

    /// @notice Current atomic pool utilization in 1e18 scale (0 to 1e18).
    /// @return utilizationWad Utilization scaled by 1e18
    function getAtomicUtilizationWad() external view returns (uint256 utilizationWad) {
        (uint256 available, uint256 allocated) = _getLiquidityForAtomicUnstaking();
        if (allocated == 0) return 0;
        uint256 frac = available * SCALE / allocated; // available / allocated in 1e18
        utilizationWad = frac >= SCALE ? 0 : (SCALE - frac);
    }

    /// @notice Current marginal unstake fee rate (RAY) under y = min(c + m*u, c + m).
    /// @return feeRateRay Fee rate in RAY (1e27)
    function getCurrentUnstakeFeeRateRay() external view returns (uint256 feeRateRay) {
        (uint256 available, uint256 allocated) = _getLiquidityForAtomicUnstaking();
        if (allocated == 0) return uint256(s_feeParams.cRay) + uint256(s_feeParams.mRay); // capped full utilization
        uint256 frac = available * SCALE / allocated;
        uint256 u = frac >= SCALE ? 0 : (SCALE - frac); // utilization in 1e18
        uint256 c = uint256(s_feeParams.cRay);
        uint256 m = uint256(s_feeParams.mRay);
        uint256 y = c + (m * u) / SCALE;
        uint256 yMax = c + m;
        feeRateRay = Math.min(yMax, y);
    }

    /// @notice Detailed atomic pool state and utilization in one call.
    /// @return utilized Amount utilized (distributed) adjusted for smoothing
    /// @return allocated Total allocated (target) for atomic pool
    /// @return available Currently available liquidity
    /// @return utilizationWad Utilization scaled to 1e18
    function getAtomicPoolUtilization()
        external
        view
        returns (uint256 utilized, uint256 allocated, uint256 available, uint256 utilizationWad)
    {
        (available, allocated) = _getLiquidityForAtomicUnstaking();
        utilized = allocated - available;
        if (allocated == 0) return (0, 0, 0, 0);
        uint256 frac = available * SCALE / allocated;
        utilizationWad = frac >= SCALE ? 0 : (SCALE - frac);
    }

    // ================================================== //
    //                Fee Math Functions                  //
    // ================================================== //

    // Forward (runtime): clamp gross by R0 and price with capped model.
    function _getGrossCappedAndFeeFromGrossAssets(uint256 grossRequested)
        internal
        view
        override
        returns (uint256 grossCapped, uint256 feeAssets)
    {
        if (grossRequested == 0) return (grossRequested, 0);
        (uint256 R0, uint256 L) = _getLiquidityForAtomicUnstaking();

        grossCapped = Math.min(grossRequested, R0);

        (feeAssets,) = FeeLib.solveNetGivenGross(grossCapped, R0, L, s_feeParams);
    }

    // Forward (for previewRedeem): no liquidity clamp; still capped rate.
    function _quoteFeeFromGrossAssetsNoLiquidityLimit(uint256 grossRequested)
        internal
        view
        override
        returns (uint256 feeAssets)
    {
        if (grossRequested == 0) return 0;

        (uint256 R0, uint256 L) = _getLiquidityForAtomicUnstaking();

        // Previews reflect fee but ignore liquidity limits. If target liquidity is zero,
        // use the library's flat max-fee path (treats the interval as fully capped).
        if (L == 0) {
            (feeAssets,) = FeeLib.solveNetGivenGross_FlatMaxFee(grossRequested, s_feeParams);
            return feeAssets;
        }

        (feeAssets,) = FeeLib.solveNetGivenGross(grossRequested, R0, L, s_feeParams);
    }

    // Inverse (runtime): limited by available liquidity
    function _getGrossAndFeeFromNetAssets(uint256 netAssets)
        internal
        view
        returns (uint256 grossAssets, uint256 feeAssets)
    {
        (uint256 R0, uint256 L) = _getLiquidityForAtomicUnstaking();

        if (netAssets == 0) return (netAssets, 0);

        // If target liquidity is zero, it should apply the max fee (at u=1), and also cap gross to current liquidity.
        (grossAssets, feeAssets) = FeeLib.solveGrossGivenNet(netAssets, R0, L, R0, s_feeParams);
    }

    // Inverse (for previewWithdraw): no liquidity limit
    function _quoteGrossAndFeeFromNetAssetsNoLiquidityLimit(uint256 targetNet)
        internal
        view
        override
        returns (uint256 gross, uint256 fee)
    {
        (uint256 R0, uint256 L) = _getLiquidityForAtomicUnstaking();

        if (targetNet == 0) return (0, 0);

        // Previews reflect fee but ignore liquidity limits. If target liquidity is zero,
        // use the library's flat max-fee inverse path (fully capped assumption).
        if (L == 0) {
            (gross, fee) = FeeLib.solveGrossGivenNet_FlatMaxFee(targetNet, s_feeParams);
            return (gross, fee);
        }

        (gross, fee) = FeeLib.solveGrossGivenNet(targetNet, R0, L, 0, s_feeParams);
    }

    // ================================================== //
    //            Internal Accounting Helpers             //
    // ================================================== //

    function _getTargetLiquidity() internal view returns (uint128 targetLiquidity) {
        // Calculate target liquidity as a percentage of total assets
        targetLiquidity = s_atomicAssets.allocatedAmount;
    }
}
