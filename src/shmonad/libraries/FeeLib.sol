// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.8.28 <0.9.0;

import { FixedPointMathLib as Math } from "@solady/utils/FixedPointMathLib.sol";
import { FeeParams } from "../Types.sol";
import { BPS_SCALE, RAY } from "../Constants.sol";

/// @notice Fee math for capped-linear utilization model:
///         r(u) = min(c + m*u, c + m), with u in WAD and assets in raw units.
/// - Rates m, c are in RAY (1e27).
/// - Utilization u is in WAD (1e18), with u = max(0, 1 - R/L).
library FeeLib {
    // ----------- Scales -----------
    uint256 internal constant WAD = 1e18;
    uint256 constant RAY_WAD = 1e45; // RAY * WAD
    uint256 constant RAY_WAD2 = 1e63; // RAY * WAD * WAD

    // ================================================================
    // Helpers
    // ================================================================

    /// @notice Forward fee with a flat maximum fee rate rMax = c + m (RAY). Ignores liquidity and utilization.
    /// @dev Used for preview paths when target liquidity L == 0; treats the pool as fully capped across the interval.
    function solveNetGivenGross_FlatMaxFee(
        uint256 g,
        FeeParams memory p
    )
        internal
        pure
        returns (uint256 fee, uint256 net)
    {
        if (g == 0) return (0, 0);
        uint256 rMax = uint256(p.cRay) + uint256(p.mRay);
        if (rMax >= RAY) {
            fee = g; // 100% fee wall
        } else {
            fee = Math.mulDiv(g, rMax, RAY);
        }
        net = g - fee;
    }

    /// @notice Inverse solve with flat maximum fee rate rMax = c + m (RAY). Ignores liquidity and utilization.
    /// @dev Used for preview paths when target liquidity L == 0; solves g = ceil(N / (1 - rMax)).
    function solveGrossGivenNet_FlatMaxFee(
        uint256 targetNet,
        FeeParams memory p
    )
        internal
        pure
        returns (uint256 gross, uint256 fee)
    {
        if (targetNet == 0) return (0, 0);

        uint256 rMax = uint256(p.cRay) + uint256(p.mRay);
        if (rMax >= RAY) {
            // No positive net achievable at or above 100% fee.
            return (0, 0);
        }

        gross = Math.mulDivUp(targetNet, RAY, (RAY - rMax));
        fee = gross - targetNet;
    }

    /// @notice u0 in WAD from current liquidity R0 and target L.
    /// @dev u0 = max(0, 1 - R0/L). If L == 0, returns 0 (caller should guard).
    function utilFromLiquidity(uint256 R0, uint256 L) internal pure returns (uint256 u0Wad) {
        if (L == 0) return 0;
        // 1 - R0/L, scaled to WAD: u0 = WAD - (R0 * WAD / L)
        uint256 frac = Math.mulDiv(R0, WAD, L);
        // Clamp at 0 if R0 > L (over-supplied pool => treat as u=0)
        u0Wad = frac >= WAD ? 0 : (WAD - frac);
    }

    /// @notice Integral over [uA,uB] of the *uncapped* linear rate r(u)=c + m*u, scaled to asset fee by multiplying L.
    /// @dev Returns fee in asset units. Assumes uB >= uA. Pure helper for the capped integral.
    function _feeIntegralLinear(
        uint256 uA, // WAD
        uint256 uB, // WAD
        uint256 L, // assets
        uint256 baseRay, // c (RAY)
        uint256 slopeRay // m (RAY)
    )
        private
        pure
        returns (uint256 fee)
    {
        if (uB <= uA || L == 0) return 0;

        unchecked {
            // term1 = c * (uB - uA)
            uint256 dU = uB - uA; // Result is WAD

            // Use difference-of-squares as Δ(u^2) = (uB - uA) * (uB + uA).
            uint256 dU2 = Math.fullMulDiv(dU, uA + uB, 1); // Result is WAD^2

            // term1 numerator: baseRay * Δu  (RAY * WAD).
            // Using fullMulDiv(*, *, 1) gives us an exact 512-bit multiply without overflow.
            uint256 t1Num = Math.fullMulDiv(baseRay, dU, 1);

            // term2 numerator: (slopeRay * Δ(u^2)) / 2  -> (RAY * WAD^2)/2.
            // Do the divide-by-2 here (floor) to mirror original semantics.
            uint256 t2Num = Math.fullMulDiv(slopeRay, dU2, 2);

            // fee = L * [ t1Num/(RAY*WAD) + t2Num/(RAY*WAD^2) ].
            // Each fullMulDiv performs a 512-bit (L * numerator) / denominator with floor rounding.
            uint256 t1 = Math.fullMulDiv(L, t1Num, RAY_WAD);
            uint256 t2 = Math.fullMulDiv(L, t2Num, RAY_WAD2);

            fee = t1 + t2;
        }
    }

    function _tightenGrossDown(
        uint256 gross,
        uint256 targetNet,
        uint256 R0,
        uint256 L,
        FeeParams memory p
    )
        private
        pure
        returns (uint256)
    {
        if (gross == 0) return 0;

        // If gross-1 already fails, gross is minimal
        (, uint256 netMinus) = solveNetGivenGross(gross - 1, R0, L, p);
        if (netMinus < targetNet) return gross;

        // Compute the excess at gross
        (, uint256 netG) = solveNetGivenGross(gross, R0, L, p);
        uint256 excess = netG - targetNet; // > 0 here

        // dMin = 1 - rMax/RAY  (in RAY units as numerator)
        uint256 c = uint256(p.cRay);
        uint256 m = uint256(p.mRay);
        uint256 rMax = c + m;
        if (rMax >= RAY) return gross; // 100% fee region; derivative ~ 0, nothing to tighten.

        uint256 dMinRay = RAY - rMax; // in RAY
        // minGrossDrop = ceil(excess / dMin) = ceil(excess * RAY / dMinRay)
        uint256 minGrossDrop = Math.mulDivUp(excess, RAY, dMinRay);
        uint256 low = gross > minGrossDrop ? gross - minGrossDrop : 0;
        uint256 high = gross;

        // Binary search to minimal feasible g in (low, high]. Max 10 iterations.
        for (uint256 i = 0; i < 10 && low + 1 < high; ++i) {
            uint256 mid = (low + high) >> 1;
            (, uint256 netMid) = solveNetGivenGross(mid, R0, L, p);
            if (netMid >= targetNet) high = mid;
            else low = mid;
        }

        // Final micro-tighten to account for integer plateaus. Max 3 iterations.
        for (uint256 k = 0; k < 3 && high > 0; ++k) {
            (, uint256 netPrev) = solveNetGivenGross(high - 1, R0, L, p);
            if (netPrev < targetNet) break;
            unchecked {
                --high;
            }
        }
        return high; // minimal gross with net(gross) ≥ targetNet
    }

    /// @notice Integral over [u0,u1] for r(u) = min(c + m*u, c + m), scaled to asset fee by L.
    function feeIntegralCappedOverUtil(
        uint256 u0Wad,
        uint256 u1Wad,
        uint256 L,
        FeeParams memory p
    )
        internal
        pure
        returns (uint256 fee)
    {
        if (u1Wad <= u0Wad || L == 0) return 0;

        uint256 m = uint256(p.mRay);
        uint256 c = uint256(p.cRay);

        // Degenerates to constant if slope == 0.
        if (m == 0) {
            uint256 dU = u1Wad - u0Wad; // WAD
            return Math.mulDiv(L, c * dU, RAY * WAD);
        }

        // Crossing is fixed at u = WAD (100% util).
        if (u1Wad <= WAD) {
            return _feeIntegralLinear(u0Wad, u1Wad, L, c, m); // fully linear
        }

        uint256 rMax = c + m; // r(WAD)

        if (u0Wad >= WAD) {
            uint256 dU = u1Wad - u0Wad; // fully capped region
            return Math.mulDiv(L, rMax * dU, RAY * WAD);
        }

        // Crossing case: [u0, WAD] linear + [WAD, u1] constant at rMax
        unchecked {
            uint256 feeLinear = _feeIntegralLinear(u0Wad, WAD, L, c, m);
            uint256 dUConst = (u1Wad - WAD);
            uint256 feeConst = Math.mulDiv(L, rMax * dUConst, RAY * WAD);
            fee = feeLinear + feeConst;
        }
    }

    // ================================================================
    // Forward: gross -> (fee, net)
    // ================================================================

    /// @notice Compute (fee, net) for a given gross g using the capped-linear model. No liquidity clamp here.
    function solveNetGivenGross(
        uint256 g, // gross assets requested
        uint256 R0, // current liquidity
        uint256 L, // target liquidity
        FeeParams memory p
    )
        internal
        pure
        returns (uint256 fee, uint256 net)
    {
        if (g == 0) return (0, 0);

        // When target liquidity is zero (L==0), apply a flat max-fee rate.
        if (L == 0) return solveNetGivenGross_FlatMaxFee(g, p);

        unchecked {
            uint256 u0 = utilFromLiquidity(R0, L);
            // u1 = u0 + g/L (in WAD)
            uint256 dU = Math.mulDiv(g, WAD, L);
            uint256 u1 = u0 + dU;

            fee = feeIntegralCappedOverUtil(u0, u1, L, p);
            if (fee > g) fee = g; // defensive clamp
            net = g - fee;
        }
    }

    // ================================================================
    // Inverse: target net -> (gross, fee)
    // ================================================================

    /// @notice Inverse: find (gross, fee) for a target net under capped-linear model. Never reverts.
    /// @param Gcap If >0, enforces a gross cap; outputs are capped accordingly.
    function solveGrossGivenNet(
        uint256 targetNet,
        uint256 R0,
        uint256 L,
        uint256 Gcap,
        FeeParams memory p
    )
        internal
        pure
        returns (uint256 gross, uint256 fee)
    {
        // Trivial / degenerate cases
        if (targetNet == 0) return (0, 0);

        // When target liquidity is zero (L==0), apply a flat max-fee rate. Gross cap is still respected.
        if (L == 0) {
            (gross, fee) = solveGrossGivenNet_FlatMaxFee(targetNet, p);
            if (Gcap > 0 && gross > Gcap) {
                gross = Gcap;
                (fee,) = solveNetGivenGross_FlatMaxFee(gross, p);
            }
            return (gross, fee);
        }

        unchecked {
            uint256 m = uint256(p.mRay);
            uint256 c = uint256(p.cRay);
            uint256 rMax = c + m;

            uint256 u0 = utilFromLiquidity(R0, L);

            // If already in capped region (u0 >= 1) or slope==0 => constant-rate solve.
            if (m == 0 || u0 >= WAD) {
                if (rMax >= RAY) {
                    // 100% fee or above => unreachable positive net; return zero gross/fee.
                    gross = 0;
                    fee = 0;
                } else {
                    // g = ceil(N / (1 - rMax))
                    gross = Math.mulDivUp(targetNet, RAY, (RAY - rMax));
                    (fee,) = solveNetGivenGross(gross, R0, L, p);
                }
            } else {
                // Gross to reach u=1 from u0
                uint256 gCap = Math.mulDiv((WAD - u0), L, WAD);

                // Net achievable before hitting cap.
                (uint256 fee1, uint256 net1) = solveNetGivenGross(gCap, R0, L, p);

                if (targetNet <= net1) {
                    // Solve the quadratic in the fully-linear regime:
                    // N = g * (1 - (c + m*u0)) - (m/(2L)) * g^2
                    // Using scaled rearrangement:
                    // Let K = RAY - (c + floor(m*u0/WAD)) (>=0). Then:
                    // D' = K^2 - (2 * m * RAY * N) / L
                    // g  = L * (K - sqrt(D')) / m     (ceil)
                    uint256 m_u0_ray = Math.mulDiv(m, u0, WAD); // m*u0 in RAY
                    uint256 r0_ray = c + m_u0_ray; // (c + m*u0) in RAY
                    uint256 K = r0_ray >= RAY ? 0 : (RAY - r0_ray);

                    if (K == 0) {
                        gross = 0;
                        fee = 0;
                    } else {
                        uint256 two_m_RAY = m * (2 * RAY); // <= ~2e54
                        uint256 sub = Math.mulDiv(targetNet, two_m_RAY, L); // (2*m*RAY*N)/L
                        uint256 K2 = K * K;
                        uint256 Dprime = K2 > sub ? (K2 - sub) : 0;
                        uint256 sqrtD = Math.sqrt(Dprime);
                        uint256 num = (K > sqrtD) ? (K - sqrtD) : 0;

                        gross = (m == 0) ? 0 : Math.mulDivUp(L, num, m); // ceil
                        (fee,) = solveNetGivenGross(gross, R0, L, p);
                    }
                } else {
                    // Crosses into capped segment: spend g1 to u=1, then remainder at rMax.
                    uint256 remNet = targetNet - net1;
                    if (rMax >= RAY) {
                        gross = gCap; // cannot add positive net beyond cap if rMax==100%
                        (fee,) = solveNetGivenGross(gross, R0, L, p);
                    } else {
                        uint256 g2 = Math.mulDivUp(remNet, RAY, (RAY - rMax)); // ceil
                        gross = gCap + g2;
                        fee = fee1 + Math.mulDiv(g2, rMax, RAY);
                    }
                }
            }
        }

        // Tighten to the *minimal* gross that still achieves targetNet (if not capped by Gcap).
        if (gross > 0 && (Gcap == 0 || gross <= Gcap)) {
            uint256 gTight = _tightenGrossDown(gross, targetNet, R0, L, p);
            if (gTight < gross) {
                gross = gTight;
                (fee,) = solveNetGivenGross(gross, R0, L, p);
            }
        }

        // If a gross cap is provided and we exceeded it, cap outputs and recompute fee to report a consistent pair.
        if (Gcap > 0 && gross > Gcap) {
            gross = Gcap;
            (fee,) = solveNetGivenGross(gross, R0, L, p);
        }

        return (gross, fee);
    }

    // ================================================================
    // Other Math Helpers
    // ================================================================

    /// @notice Calculates the pool's target liquidity using a percentage expressed in basis points (1e4 = 100%).
    /// @dev Callers working with 1e18-scale percentages should convert via `_unscaledTargetLiquidityPercentage`.
    function calcTargetLiquidity(
        uint256 totalEquity,
        uint256 targetLiquidityPercentage
    )
        internal
        pure
        returns (uint256 targetLiquidity)
    {
        if (targetLiquidityPercentage == 0) return 0; // If targetLiqPercentage is 0, return early

        // Calculate target liquidity as a percentage of total assets
        targetLiquidity = Math.mulDiv(totalEquity, targetLiquidityPercentage, BPS_SCALE);
    }
}
