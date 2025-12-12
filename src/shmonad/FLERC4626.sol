//SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.8.28 <0.9.0;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { ReentrancyGuardTransientUpgradeable } from
    "@openzeppelin-upgradeable/contracts/utils/ReentrancyGuardTransientUpgradeable.sol";
import { SafeTransferLib } from "@solady/utils/SafeTransferLib.sol";
import { SafeCastLib } from "@solady/utils/SafeCastLib.sol";

import { FastLaneERC20 } from "./FLERC20.sol";
import { IERC4626Custom } from "./interfaces/IERC4626Custom.sol";
import {
    Epoch,
    CashFlows,
    AtomicCapital,
    StakingEscrow,
    PendingBoost,
    WorkingCapital,
    UserUnstakeRequest,
    CurrentLiabilities,
    RevenueSmoother
} from "./Types.sol";
import { NATIVE_TOKEN, SCALE, MONAD_EPOCH_LENGTH } from "./Constants.sol";

import { AccountingLib } from "./libraries/AccountingLib.sol";

import { PrecompileHelpers } from "./PrecompileHelpers.sol";

/// @author FastLane Labs
/// @dev Based on OpenZeppelin's ERC4626 implementation, with modifications to support ShMonad's storage structure.
abstract contract FastLaneERC4626 is FastLaneERC20, PrecompileHelpers, ReentrancyGuardTransientUpgradeable {
    using Math for uint256;
    using SafeCastLib for uint256;
    using SafeTransferLib for address;
    using AccountingLib for WorkingCapital;
    using AccountingLib for AtomicCapital;
    using AccountingLib for CurrentLiabilities;

    // --------------------------------------------- //
    //            ERC4626 Custom Functions           //
    // --------------------------------------------- //

    /// @notice Accepts MON which increases yield for shMON holders (to unstake pool).
    /// @dev Accepts native MON tokens via msg.value which increases yield for all shMON holders
    /// @dev The provided native tokens are not distributed but remain in the contract as yield
    function boostYield(address yieldOriginator) external payable nonReentrant {
        _handleBoostYield(msg.value.toUint128());
        emit BoostYield(_msgSender(), yieldOriginator, 0, msg.value, false);
    }

    // Burns shMON shares and converts the underlying assets into yield for all other shMON holders
    /// @dev Burns shMON shares from the specified address, effectively donating their value to other holders
    /// @dev If the sender is not the 'from' address, allowance is consumed
    /// @dev The underlying assets are not withdrawn but remain in the contract as yield for other shMON holders
    function boostYield(uint256 shares, address from, address yieldOriginator) external nonReentrant {
        uint256 _assets = _convertToAssets(shares, Math.Rounding.Floor, false, false);

        if (from != _msgSender()) {
            _spendAllowance(from, _msgSender(), shares);
        }
        _burn(from, shares);

        _handleBoostYield(_assets.toUint128());
        // emit event for extra yield
        emit BoostYield(from, yieldOriginator, 0, _assets, true);
        // Native tokens intentionally not sent - remains in ShMonad as yield
    }

    /// @notice Pays validator rewards (e.g., MEV) and applies the protocol fee split
    function sendValidatorRewards(uint64 validatorId, uint256 feeRate) external payable nonReentrant {
        require(feeRate <= SCALE, InvalidFeeRate(feeRate));
        (uint120 _validatorPayout, uint120 _feeTaken) = _handleValidatorRewards(validatorId, msg.value, feeRate);

        emit SendValidatorRewards(_msgSender(), validatorId, _validatorPayout, _feeTaken);
    }

    // --------------------------------------------- //
    //           ERC4626 Standard Functions          //
    // --------------------------------------------- //

    /**
     * @dev See {IERC4626-deposit}.
     */
    function deposit(
        uint256 assets,
        address receiver
    )
        public
        payable
        virtual
        notWhenClosed
        nonReentrant
        returns (uint256)
    {
        uint256 maxAssets = maxDeposit(receiver);
        require(assets <= maxAssets, ERC4626ExceededMaxDeposit(receiver, assets, maxAssets));

        uint256 shares = _previewDeposit(assets, true);
        _deposit(_msgSender(), receiver, assets, shares);

        return shares;
    }

    /**
     * @dev See {IERC4626-mint}.
     */
    function mint(
        uint256 shares,
        address receiver
    )
        public
        payable
        virtual
        notWhenClosed
        nonReentrant
        returns (uint256)
    {
        uint256 maxShares = maxMint(receiver);
        require(shares <= maxShares, ERC4626ExceededMaxMint(receiver, shares, maxShares));

        uint256 assets = _previewMint(shares, true);
        _deposit(_msgSender(), receiver, assets, shares);

        return assets;
    }

    // --------------------------------------------- //
    //             Atomic Unstake Functions          //
    // --------------------------------------------- //

    /**
     * @dev See {IERC4626-withdraw}.
     *
     * NOTE: The `withdraw()` function charges a fee as it uses the AtomicUnstakePool to convert shMON to MON.
     *       The fee is calculated based on the pool's utilization rate and the configured fee curve.
     *       The fee is deducted from the assets before they are sent to the receiver.
     *       To estimate the fee, use the `previewWithdraw()` function.
     */
    function withdraw(uint256 assets, address receiver, address owner) public virtual nonReentrant returns (uint256) {
        require(receiver != address(0), ZeroAddress());
        uint256 maxAssets = maxWithdraw(owner);
        require(assets <= maxAssets, ERC4626ExceededMaxWithdraw(owner, assets, maxAssets));

        (uint256 shares, uint256 feeAssets) = _previewWithdraw(assets);

        _withdraw(_msgSender(), receiver, owner, assets, shares, feeAssets);

        receiver.safeTransferETH(assets);

        return shares;
    }

    /**
     * @dev See {IERC4626-redeem}.
     *
     * NOTE: The `redeem()` function charges a fee as it uses the AtomicUnstakePool to convert shMON to MON.
     *       The fee is calculated based on the pool's utilization rate and the configured fee curve.
     *       The fee is deducted from the assets before they are sent to the receiver.
     *       To estimate the fee, use the `previewRedeem()` function.
     */
    function redeem(uint256 shares, address receiver, address owner) public virtual nonReentrant returns (uint256) {
        require(receiver != address(0), ZeroAddress());
        uint256 maxShares = maxRedeem(owner);
        require(shares <= maxShares, ERC4626ExceededMaxRedeem(owner, shares, maxShares));

        (uint256 netAssets, uint256 feeAssets) = _previewRedeem(shares);

        _withdraw(_msgSender(), receiver, owner, netAssets, shares, feeAssets);

        receiver.safeTransferETH(netAssets);

        return netAssets;
    }

    // --------------------------------------------- //
    //               Internal Functions              //
    // --------------------------------------------- //

    /**
     * @dev Internal conversion function (from assets to shares) with support for rounding direction.
     */
    function _convertToShares(
        uint256 assets,
        Math.Rounding rounding,
        bool deductRecentRevenue,
        bool deductMsgValue
    )
        internal
        view
        virtual
        override
        returns (uint256)
    {
        uint256 _equity = deductMsgValue
            ? _totalEquity({ deductRecentRevenue: deductRecentRevenue }) - msg.value
            : _totalEquity({ deductRecentRevenue: deductRecentRevenue });
        return assets.mulDiv(_realTotalSupply() + 10 ** _decimalsOffset(), _equity + 1, rounding);
    }

    /**
     * @dev Internal conversion function (from shares to assets) with support for rounding direction.
     */
    function _convertToAssets(
        uint256 shares,
        Math.Rounding rounding,
        bool deductRecentRevenue,
        bool deductMsgValue
    )
        internal
        view
        virtual
        returns (uint256)
    {
        uint256 _equity = deductMsgValue
            ? _totalEquity({ deductRecentRevenue: deductRecentRevenue }) - msg.value
            : _totalEquity({ deductRecentRevenue: deductRecentRevenue });
        return shares.mulDiv(_equity + 1, _realTotalSupply() + 10 ** _decimalsOffset(), rounding);
    }

    /**
     * @dev Deposit/mint common workflow.
     */
    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal virtual {
        require(assets == msg.value, InsufficientNativeTokenSent());

        _mint(receiver, shares);

        // Call StakeTracker hook to account for newly deposited assets
        _accountForDeposit(assets);

        emit Deposit(caller, receiver, assets, shares);
    }

    /**
     * @dev Withdraw/redeem common workflow.
     */
    function _withdraw(
        address caller,
        address receiver,
        address owner,
        uint256 netAssets,
        uint256 shares,
        uint256 feeAssets
    )
        internal
        virtual
    {
        if (caller != owner) {
            _spendAllowance(owner, caller, shares);
        }

        _burn(owner, shares);

        // Tracker bookkeeping: record net assets delivered and fee charged
        _accountForWithdraw(netAssets.toUint128(), feeAssets.toUint128());

        // ERC-4626 semantics: emit event with actual assets delivered to receiver
        emit Withdraw(caller, receiver, owner, netAssets, shares);
    }

    function _previewDeposit(uint256 assets, bool deductMsgValue) internal view virtual returns (uint256) {
        bool _deductRecentRevenue = false;
        return _convertToShares(assets, Math.Rounding.Floor, _deductRecentRevenue, deductMsgValue);
    }

    function _previewMint(uint256 shares, bool deductMsgValue) internal view virtual returns (uint256) {
        bool _deductRecentRevenue = false;
        return _convertToAssets(shares, Math.Rounding.Ceil, _deductRecentRevenue, deductMsgValue);
    }

    function _decimalsOffset() internal view virtual returns (uint8) {
        return 0;
    }

    // --------------------------------------------- //
    //                 View Functions                //
    // --------------------------------------------- //

    /**
     * @dev See {IERC4626-asset}.
     */
    function asset() public view virtual returns (address) {
        return NATIVE_TOKEN;
    }

    /**
     * @dev Returns the real total assets attributed to real, minted shMON.
     * NOTE: The asset balance attributed to shMON holders and excludes debts / creditor balances is called EQUITY.
     */
    function totalAssets() public view virtual returns (uint256) {
        // NOTE: Does not include MON earmarked for traditional unstaking (tracked in reservedAmount). Those funds have
        // already been deducted from total balances, so they can be excluded from ShMonad's liquid MON balance.
        return _totalEquity({ deductRecentRevenue: false });
    }

    /**
     * @dev Returns the total assets attributed to real, minted shMON. AKA equity.
     */
    function _totalEquity(bool deductRecentRevenue) internal view virtual override returns (uint256) {
        WorkingCapital memory _globalCapital = s_globalCapital;
        uint256 _equity = _globalCapital.totalEquity(s_globalLiabilities, s_admin, address(this).balance);
        if (deductRecentRevenue) {
            uint256 _recentRevenue = _recentRevenueOffset();
            return _equity > _recentRevenue ? _equity - _recentRevenue : 0;
        }
        return _equity;
    }

    /**
     * @dev Returns any recently-earned revenue that should not be included in totalAssets in order to mitigate the
     *     dilutive impact of JIT LPing on unusually large revenue.
     */
    function _recentRevenueOffset() internal view virtual returns (uint256) {
        RevenueSmoother memory _revenueSmoother = s_revenueSmoother;
        uint256 _blocksSinceEpochChange = block.number - uint256(_revenueSmoother.epochChangeBlockNumber);
        if (_blocksSinceEpochChange > MONAD_EPOCH_LENGTH) {
            return uint256(globalRewardsPtr_N(0).earnedRevenue);
        }
        uint256 _lastRevenue = _revenueSmoother.earnedRevenueLast;
        uint256 _unearnedBlocks = MONAD_EPOCH_LENGTH - _blocksSinceEpochChange;
        uint256 _unearnedRevenue = _lastRevenue * _unearnedBlocks / MONAD_EPOCH_LENGTH;
        return uint256(globalRewardsPtr_N(0).earnedRevenue) + _unearnedRevenue;
    }

    /**
     * @dev See {IERC4626-convertToShares}.
     */
    function convertToShares(uint256 assets) public view virtual returns (uint256) {
        bool _deductRecentRevenue = true;
        return _convertToShares(assets, Math.Rounding.Floor, _deductRecentRevenue, false);
    }

    /**
     * @dev See {IERC4626-convertToAssets}.
     */
    function convertToAssets(uint256 shares) public view virtual returns (uint256) {
        bool _deductRecentRevenue = true;
        return _convertToAssets(shares, Math.Rounding.Floor, _deductRecentRevenue, false);
    }

    /**
     * @dev See {IERC4626-maxDeposit}.
     */
    function maxDeposit(address) public view virtual returns (uint256) {
        return type(uint128).max;
    }

    /**
     * @dev See {IERC4626-maxMint}.
     */
    function maxMint(address) public view virtual returns (uint256) {
        return type(uint128).max;
    }

    /**
     * @dev See {IERC4626-maxWithdraw}.
     */
    function maxWithdraw(address owner) public view virtual returns (uint256) {
        uint256 _shares = balanceOf(owner);

        // Convert shares to assets
        bool _deductRecentRevenue = true;
        uint256 _assets = _convertToAssets(_shares, Math.Rounding.Floor, _deductRecentRevenue, false);

        // Apply AtomicUnstakePool fee to assets, based on pool utilization
        (uint256 _grossAssetsCapped, uint256 _feeAssets) = _getGrossCappedAndFeeFromGrossAssets(_assets);

        return _grossAssetsCapped - _feeAssets;
    }

    /**
     * @dev See {IERC4626-maxRedeem}.
     */
    function maxRedeem(address owner) public view virtual returns (uint256) {
        // `maxWithdraw()` factors in fee and liquidity limits
        uint256 maxWithdrawAssetsAfterFee = maxWithdraw(owner);

        // Then, use `previewWithdraw()` to go from netAssets back to gross shares, as per ERC-4626 semantics.
        return previewWithdraw(maxWithdrawAssetsAfterFee);
    }

    /**
     * @dev See {IERC4626-previewDeposit}.
     */
    function previewDeposit(uint256 assets) public view virtual returns (uint256) {
        bool _deductRecentRevenue = false;
        return _convertToShares(assets, Math.Rounding.Floor, _deductRecentRevenue, false);
    }

    /**
     * @dev See {IERC4626-previewMint}.
     */
    function previewMint(uint256 shares) public view virtual returns (uint256) {
        return _previewMint(shares, false);
    }

    /**
     * @dev See {IERC4626-previewWithdraw}.
     */
    function previewWithdraw(uint256 assets) public view virtual returns (uint256) {
        (uint256 shares,) = _previewWithdraw(assets);
        return shares;
    }

    function _previewWithdraw(uint256 assets) internal view virtual returns (uint256 shares, uint256 feeAssets) {
        // Non-reverting inverse: treats `assets` as post-fee and computes the before-fee amount,
        // ignoring current liquidity limits per ERC-4626 preview requirements.

        uint256 _beforeFeeAssets;
        (_beforeFeeAssets, feeAssets) = _quoteGrossAndFeeFromNetAssetsNoLiquidityLimit(assets);

        // Convert before-fee assets to shares
        bool _deductRecentRevenue = true;
        shares = _convertToShares(_beforeFeeAssets, Math.Rounding.Ceil, _deductRecentRevenue, false);
    }

    /**
     * @dev See {IERC4626-previewRedeem}.
     */
    function previewRedeem(uint256 shares) public view virtual returns (uint256) {
        (uint256 netAssets,) = _previewRedeem(shares);
        return netAssets;
    }

    // --------------------------------------------- //
    //                 View Functions                //
    // --------------------------------------------- //

    /// @notice Detailed preview for redeem: splits gross, fee, and net assets.
    /// @param shares Amount of shMON to redeem
    /// @return grossAssets Gross assets before fee
    /// @return feeAssets Fee charged based on atomic pool utilization
    /// @return netAssets Net assets received by the receiver
    function previewRedeemDetailed(uint256 shares)
        external
        view
        returns (uint256 grossAssets, uint256 feeAssets, uint256 netAssets)
    {
        bool _deductRecentRevenue = true;
        grossAssets = _convertToAssets(shares, Math.Rounding.Floor, _deductRecentRevenue, false);
        feeAssets = _quoteFeeFromGrossAssetsNoLiquidityLimit(grossAssets);
        netAssets = grossAssets - feeAssets;
    }

    /// @notice Detailed preview for withdraw-by-assets: splits shares and fee breakdown.
    /// @param netAssets Target net assets to withdraw
    /// @return shares Shares to burn for the withdrawal
    /// @return grossAssets Gross assets before fee corresponding to `netAssets`
    /// @return feeAssets Fee charged based on atomic pool utilization
    function previewWithdrawDetailed(uint256 netAssets)
        external
        view
        returns (uint256 shares, uint256 grossAssets, uint256 feeAssets)
    {
        (grossAssets, feeAssets) = _quoteGrossAndFeeFromNetAssetsNoLiquidityLimit(netAssets);
        bool _deductRecentRevenue = true;
        shares = _convertToShares(grossAssets, Math.Rounding.Ceil, _deductRecentRevenue, false);
    }

    function _previewRedeem(uint256 shares) internal view virtual returns (uint256 netAssets, uint256 feeAssets) {
        // Treat the asset value of `shares` as gross ask and run the limit-aware forward model once; use its clamped
        // net for preview.
        bool _deductRecentRevenue = true;
        uint256 _grossAssets = _convertToAssets(shares, Math.Rounding.Floor, _deductRecentRevenue, false);
        feeAssets = _quoteFeeFromGrossAssetsNoLiquidityLimit(_grossAssets);
        netAssets = _grossAssets - feeAssets;
    }

    /**
     * @dev Similar to {IERC4626-previewRedeem}.
     */
    function previewUnstake(uint256 shares) public view virtual returns (uint256) {
        bool _deductRecentRevenue = true;
        return _convertToAssets(shares, Math.Rounding.Floor, _deductRecentRevenue, false);
    }

    // ================================================== //
    //           AtomicUnstakePool Functions              //
    // ================================================== //

    function _quoteFeeFromGrossAssetsNoLiquidityLimit(uint256 grossRequested)
        internal
        view
        virtual
        returns (uint256 feeAssets);

    function _getGrossCappedAndFeeFromGrossAssets(uint256 grossRequested)
        internal
        view
        virtual
        returns (uint256 grossCapped, uint256 feeAssets);

    function _quoteGrossAndFeeFromNetAssetsNoLiquidityLimit(uint256 targetNet)
        internal
        view
        virtual
        returns (uint256 gross, uint256 fee);

    function _handleBoostYield(uint128 amount) internal virtual;

    function _handleValidatorRewards(
        uint64 valId,
        uint256 amount,
        uint256 feeRate
    )
        internal
        virtual
        returns (uint120 validatorPayout, uint120 feeTaken);

    function _accountForWithdraw(uint256 netAmount, uint256 fee) internal virtual;

    function _accountForDeposit(uint256 assets) internal virtual;

    function _afterRequestUnstake(uint256 amount) internal virtual;

    function _beforeCompleteUnstake(uint128 amount) internal virtual;
}
