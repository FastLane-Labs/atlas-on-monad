//SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.8.28 <0.9.0;

import { SafeTransferLib } from "@solady/utils/SafeTransferLib.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import { Math as OZMath } from "@openzeppelin/contracts/utils/math/Math.sol";

// OVERRIDE STUFF
import { Policies } from "./Policies.sol";
import { CommittedData, Delivery, UserUnstakeRequest, WorkingCapital } from "./Types.sol";
import { EIP1967_ADMIN_SLOT } from "./Constants.sol";
import { IShMonad } from "./interfaces/IShMonad.sol";
import { AccountingLib } from "./libraries/AccountingLib.sol";

/**
 * @title ShMonad - Liquid Staking Token on Monad
 * @notice ShMonad is an LST integrated with the FastLane ecosystem
 * @dev Extends Policies which provides ERC4626 functionality plus policy-based commitment mechanisms
 * @author FastLane Labs
 */
contract ShMonad is Policies {
    using SafeTransferLib for address;
    using SafeCast for uint256;
    using AccountingLib for WorkingCapital;

    constructor() {
        // Disable initializers on implementation
        _disableInitializers();
    }

    /**
     * @notice Initializes the contract with ownership set to the deployer
     * @dev This is part of the OpenZeppelin Upgradeable pattern
     * @dev Protected against front-running: constructor disables initializers on implementation
     * @dev For proxy upgrades, this must be called via ProxyAdmin.upgradeAndCall()
     * @param deployer The address that will own the contract
     */
    function initialize(address deployer) public reinitializer(10) {
        // Prevent unauthorized initialization during upgrades
        // Only allow if called by current owner (for upgrades)
        address _proxyAdmin = _getProxyAdmin();
        require(msg.sender == _proxyAdmin, UnauthorizedInitializer());

        __EIP712_init("ShMonad", "3");
        __Ownable_init(deployer);
        __AtomicUnstakePool_init();
        __ReentrancyGuardTransient_init();
        __StakeTracker_init();
    }

    /// @dev Returns the proxy admin when running behind a TransparentUpgradeableProxy.
    function _getProxyAdmin() private view returns (address _proxyAdmin) {
        // Assembly required to sload the admin slot defined by the proxy standard.
        // Pseudocode: proxyAdmin = StorageSlot(EIP1967_ADMIN_SLOT).read();
        assembly ("memory-safe") {
            _proxyAdmin := sload(EIP1967_ADMIN_SLOT)
        }
    }

    // --------------------------------------------- //
    //                 Agent Functions               //
    // --------------------------------------------- //

    /**
     * @inheritdoc IShMonad
     * @dev Implementation details:
     * 1. Releases any holds on the source account if requested
     * 2. If `inUnderlying` is true, interprets `amount` as MON (post-fee, ignoring liquidity limits) and
     *    converts to shares via `_convertToShares(amount)` semantics.
     * 3. Updates the source account's committed balance in memory then persists to storage
     * 4. Updates the destination account's committed balance directly in storage
     * 5. Does not decrease committedTotalSupply as the value remains in committed form
     */
    function agentTransferFromCommitted(
        uint64 policyID,
        address from,
        address to,
        uint256 amount,
        uint256 fromReleaseAmount,
        bool inUnderlying
    )
        external
        nonReentrant
        onlyPolicyAgentAndActive(policyID)
    {
        // Release hold on `from` account if necessary
        if (fromReleaseAmount > 0) _release(policyID, from, fromReleaseAmount);
        // Interpret `amount` in underlying units using the vault exchange rate (no fee path)
        if (inUnderlying) amount = _convertToShares(amount, OZMath.Rounding.Ceil, false, false);

        uint128 sharesToDeduct = amount.toUint128();

        // Changes to the `from` account - done in memory then persisted to storage:
        // - decrease committed balance (respecting any holds if not released above)
        // - do not decrease committedTotalSupply (value stays in committed form)
        CommittedData memory fromCommittedData = s_committedData[policyID][from];
        _spendFromCommitted(fromCommittedData, policyID, from, sharesToDeduct, Delivery.Committed);
        s_committedData[policyID][from] = fromCommittedData;

        // Changes to the `to` account - done directly in storage:
        // - increase committed balance (holds not applicable if increasing)
        s_committedData[policyID][to].committed += sharesToDeduct;
        s_balances[to].committed += sharesToDeduct;

        emit AgentTransferFromCommitted(policyID, from, to, amount);
    }

    /**
     * @inheritdoc IShMonad
     * @dev Implementation details:
     * 1. Prevents agents from uncommitting their own balance
     * 2. Releases any holds on the source account if requested
     * 3. If `inUnderlying` is true, interprets `amount` as MON (post-fee, ignoring liquidity limits) and
     *    converts to shares via `_convertToShares(amount)` semantics.
     * 4. Updates the source account's committed balance in memory then persists to storage
     * 5. Increases the destination account's uncommitted balance
     * 6. Decreases committedTotalSupply since value is leaving the committed form
     */
    function agentTransferToUncommitted(
        uint64 policyID,
        address from,
        address to,
        uint256 amount,
        uint256 fromReleaseAmount,
        bool inUnderlying
    )
        external
        onlyPolicyAgentAndActive(policyID)
    {
        // Agents cannot instantly uncommit their own or other agents' balances
        require(!_isPolicyAgent(policyID, from), AgentInstantUncommittingDisallowed(policyID, from));

        // Release hold on `from` account if necessary
        if (fromReleaseAmount > 0) _release(policyID, from, fromReleaseAmount);
        // Interpret `amount` in underlying units using the vault exchange rate (no fee path)
        if (inUnderlying) amount = _convertToShares(amount, OZMath.Rounding.Ceil, false, false);

        uint128 sharesToDeduct = amount.toUint128();

        // Changes to the `from` account - done in memory then persisted to storage:
        // - decrease committed balance (respecting any holds if not released above)
        // - decreases committedTotalSupply (value converts to uncommitted form)
        CommittedData memory fromCommittedData = s_committedData[policyID][from];
        _spendFromCommitted(fromCommittedData, policyID, from, sharesToDeduct, Delivery.Uncommitted);
        s_committedData[policyID][from] = fromCommittedData;

        // Increase uncommitted balance
        s_balances[to].uncommitted += sharesToDeduct;

        emit AgentTransferToUncommitted(policyID, from, to, amount);
    }

    /**
     * @inheritdoc IShMonad
     * @dev Implementation details:
     * 1. Prevents agents from withdrawing their own balance
     * 2. Releases any holds on the source account if requested
     * 3. Handles conversion between shares and assets based on inUnderlying flag
     * 4. Updates the source account's committed balance in memory then persists to storage
     * 5. Temporarily increases the destination's uncommitted balance
     * 6. Burns the shares from the destination account
     * 7. Transfers the underlying assets (MON) to the destination
     *
     * NOTE: The conversion from shares to assets is done via the AtomicUnstakePool, and the unstake fee is applied in
     * the `previewWithdraw()` and `previewRedeem()` functions. Additionally, the withdrawable amount is limited by the
     * available liquidity in the pool. It is advised that the agent first calls `previewWithdraw()` or
     * `previewRedeem()` to check the impact of these limitations on the amount of MON they can actually withdraw,
     * before calling this function.
     */
    function agentWithdrawFromCommitted(
        uint64 policyID,
        address from,
        address to,
        uint256 amount,
        uint256 fromReleaseAmount,
        bool inUnderlying
    )
        external
        nonReentrant
        onlyPolicyAgentAndActive(policyID)
    {
        // Agents cannot instantly uncommit their own or other agents' balances
        require(!_isPolicyAgent(policyID, from), AgentInstantUncommittingDisallowed(policyID, from));

        // Release hold on `from` account if necessary
        if (fromReleaseAmount > 0) _release(policyID, from, fromReleaseAmount);

        uint128 _sharesToDeduct;
        uint256 _assetsToReceive;
        uint256 _feeTaken;

        if (inUnderlying) {
            // amount = MON (post-fee). Enforce feasibility under current liquidity/fee curve.
            _assetsToReceive = amount;
            uint256 _grossAssets;
            (_grossAssets, _feeTaken) = _getGrossAndFeeFromNetAssets(_assetsToReceive);
            // Burn shares equivalent to the required before-fee gross (ceil rounding).
            _sharesToDeduct = _convertToShares(_grossAssets, OZMath.Rounding.Ceil, true, false).toUint128();
        } else {
            // amount = shMON shares. Compute deliverable assets via forward, clamped path.
            uint256 _grossAssetsWanted = _convertToAssets(amount, OZMath.Rounding.Floor, true, false);
            uint256 _grossAssetsCapped;
            (_grossAssetsCapped, _feeTaken) = _getGrossCappedAndFeeFromGrossAssets(_grossAssetsWanted);
            _assetsToReceive = _grossAssetsCapped - _feeTaken;
            _sharesToDeduct = amount.toUint128();
        }

        // Changes to the `from` account - done in memory then persisted to storage:
        // - decrease committed balance (respecting any holds if not released above)
        // - decrease committedTotalSupply (value leaving committed form)
        CommittedData memory fromCommittedData = s_committedData[policyID][from];
        _spendFromCommitted(fromCommittedData, policyID, from, _sharesToDeduct, Delivery.Underlying);
        s_committedData[policyID][from] = fromCommittedData;

        // Call StakeTracker hook to account for assets leaving via instant unstake
        _accountForWithdraw(_assetsToReceive.toUint128(), _feeTaken.toUint128());

        // Send net assets to the `to` address
        to.safeTransferETH(_assetsToReceive);

        emit AgentWithdrawFromCommitted(policyID, from, to, _assetsToReceive);
    }

    /**
     * @inheritdoc IShMonad
     * @dev Implementation details:
     * 1. Releases any holds on the source account if requested
     * 2. Handles conversion between shares and assets based on inUnderlying flag
     * 3. Updates the source account's committed balance in memory then persists to storage
     * 4. Temporarily increases the source's uncommitted balance
     * 5. Burns the shares from the source account
     * 6. The burning of shares effectively boosts yield for all remaining shareholders
     * 7. Unlike agentWithdrawFromCommitted, no assets are transferred out, improving the shares:assets ratio
     */
    function agentBoostYieldFromCommitted(
        uint64 policyID,
        address from,
        uint256 amount,
        uint256 fromReleaseAmount,
        bool inUnderlying
    )
        external
        onlyPolicyAgentAndActive(policyID)
    {
        // Release hold on `from` account if necessary
        if (fromReleaseAmount > 0) _release(policyID, from, fromReleaseAmount);

        uint128 sharesToDeduct;
        uint256 assetsToReceive;

        if (inUnderlying) {
            // amount specified in MON; interpret via exchange rate (no fee path)
            assetsToReceive = amount;
            // Convert to shares via exchange rate (no fee path)
            sharesToDeduct = _convertToShares(amount, OZMath.Rounding.Ceil, false, false).toUint128();
        } else {
            // amount = shMON
            assetsToReceive = _convertToAssets(amount, OZMath.Rounding.Floor, false, false);
            sharesToDeduct = amount.toUint128();
        }

        // Changes to the `from` account - done in memory then persisted to storage:
        // - decrease committed balance (respecting any holds if not released above)
        // - decrease committedTotalSupply (value leaving committed form)
        CommittedData memory fromCommittedData = s_committedData[policyID][from];

        // NOTE: Delivery out is marked in Underlying to convey that the supply is being burned
        // NOTE: No ClearingHouse integration is needed here
        _spendFromCommitted(fromCommittedData, policyID, from, sharesToDeduct, Delivery.Underlying);

        s_committedData[policyID][from] = fromCommittedData;

        _handleBoostYield(assetsToReceive.toUint128());

        emit AgentBoostYieldFromCommitted(policyID, from, assetsToReceive);
    }

    // --------------------------------------------- //
    //            Unstake Functions                  //
    // --------------------------------------------- //

    function requestUnstake(uint256 shares) external notWhenClosed returns (uint64 completionEpoch) {
        completionEpoch = _requestUnstake(shares);
    }

    function _requestUnstake(uint256 shares) internal returns (uint64 completionEpoch) {
        require(shares != 0, CommitRecipientCannotBeZeroAddress());
        require(shares <= balanceOf(msg.sender), InsufficientBalanceForUnstake());

        uint256 amount = previewUnstake(shares);
        uint256 _maximumGlobalRedemptions = s_globalCapital.maximumNewGlobalRedemptionAmount(
            s_globalLiabilities, s_admin, s_globalPending, s_atomicAssets, address(this).balance
        );
        if (amount > _maximumGlobalRedemptions) {
            revert ExceededMaxAmountRedeemedThisEpoch(amount, _maximumGlobalRedemptions);
        }

        uint128 _amount = amount.toUint128();

        // burn shMON → record request into global trackers
        _burn(msg.sender, shares);
        _afterRequestUnstake(_amount);

        // Use precompile epoch (no block.number)
        uint64 _currentInternalEpoch = s_admin.internalEpoch;
        // Users can complete [k + 3] after the native withdrawal delay k
        completionEpoch = _currentInternalEpoch + STAKING_WITHDRAWAL_DELAY + 3;

        // store per-user
        s_unstakeRequests[msg.sender].amountMon += _amount;
        s_unstakeRequests[msg.sender].completionEpoch = completionEpoch;

        emit RequestUnstake(msg.sender, shares, _amount, completionEpoch);
    }

    function completeUnstake() external virtual notWhenClosed {
        _completeUnstake(msg.sender);
    }

    function _completeUnstake(address account) internal {
        // pull request
        uint64 _currentInternalEpoch = s_admin.internalEpoch;
        UserUnstakeRequest memory _unstakeRequest = s_unstakeRequests[account];
        require(_unstakeRequest.amountMon != 0, NoUnstakeRequestFound());
        require(
            _currentInternalEpoch >= _unstakeRequest.completionEpoch,
            CompletionEpochNotReached(_currentInternalEpoch, _unstakeRequest.completionEpoch)
        );

        uint128 _amount = _unstakeRequest.amountMon;
        delete s_unstakeRequests[account];

        _beforeCompleteUnstake(_amount);

        account.safeTransferETH(_amount);

        emit CompleteUnstake(account, _amount);
    }
}
