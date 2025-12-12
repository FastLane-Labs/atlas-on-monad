//SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.8.28 <0.9.0;

import { IERC4626Custom } from "./IERC4626Custom.sol";
import { IERC20Full } from "./IERC20Full.sol";

import { Policy, UncommitApproval } from "../Types.sol";
import { IERC4626Custom } from "./IERC4626Custom.sol";
import { IERC20Full } from "./IERC20Full.sol";

/**
 * @title IShMonad - Interface for the ShMonad Liquid Staking Token contract
 * @notice Interface for the ShMonad contract which provides ERC4626 functionality plus policy-based commitment
 * mechanisms
 * @dev Extends ERC4626Custom and full ERC20 functionality
 */
interface IShMonad is IERC4626Custom, IERC20Full {
    // --------------------------------------------- //
    //             Extra ERC4626 Functions           //
    // --------------------------------------------- //

    /**
     * @notice Boosts yield by sending MON directly to the contract (routes to unstake pool)
     * @dev Uses msg.value for the yield boost
     */
    function boostYield(address yieldOriginator) external payable;

    /**
     * @notice Boosts yield by using a specific address's shares
     * @param shares The amount of shMON shares to use for boosting yield
     * @param from The address providing the shares
     * @param yieldOriginator The address originating the yield boost
     */
    function boostYield(uint256 shares, address from, address yieldOriginator) external;

    /**
     * @notice Credits validator rewards (e.g. MEV) to StakeTracker, splitting protocol fee vs validator payout
     * @dev Caller must pass the validator ID for attribution
     * @param validatorId The ID of the validator to attribute rewards to
     * @param feeRate The fee rate to apply to the validator reward (1e18 = 100%)
     */
    function sendValidatorRewards(uint64 validatorId, uint256 feeRate) external payable;

    // --------------------------------------------- //
    //                Account Functions              //
    // --------------------------------------------- //

    /**
     * @notice Commits shMON shares to a specific policy
     * @param policyID The ID of the policy to commit shares to
     * @param commitRecipient The address that will own the committed shares
     * @param shares The amount of shMON shares to commit
     */
    function commit(uint64 policyID, address commitRecipient, uint256 shares) external;

    /**
     * @notice Deposits MON and commits the resulting shMON shares to a specific policy
     * @param policyID The ID of the policy to commit shares to
     * @param commitRecipient The address that will own the committed shares
     * @param shMonToCommit The amount of shMON shares to commit (or type(uint256).max to commit all newly minted
     * shares)
     */
    function depositAndCommit(uint64 policyID, address commitRecipient, uint256 shMonToCommit) external payable;

    /**
     * @notice Requests uncommitment of shares from a policy, starting the escrow period before completion
     * @param policyID The ID of the policy to request uncommitment from
     * @param shares The amount of shMON shares to request uncommitment for
     * @param newMinBalance The new minimum balance to maintain (affects top-up settings)
     * @return uncommitCompleteBlock The block number when the uncommitting period will be complete
     */
    function requestUncommit(
        uint64 policyID,
        uint256 shares,
        uint256 newMinBalance
    )
        external
        returns (uint256 uncommitCompleteBlock);

    /**
     * @notice Requests uncommitment and sets/updates an approval for who can later complete it
     * @dev Approval behavior: accumulates share allowance and overrides the approver address.
     *      - Shares: adds the requested `shares` to the existing approval allowance for future completions.
     *      - Completor: sets/overrides the approved `completor` for subsequent completions.
     *      - Open approval: pass `address(0)` for `completor` to allow anyone to call `completeUncommitWithApproval()`.
     *      - Infinite approval: `type(uint96).max` represents an unlimited share allowance.
     * @param policyID The ID of the policy to request uncommitment from
     * @param shares The amount of shMON shares to request uncommitment for (also added to approval allowance)
     * @param newMinBalance The new minimum balance to maintain (affects top-up settings)
     * @param completor The address authorized to complete uncommitment (zero address allows anyone)
     * @return uncommitCompleteBlock The block number when the uncommitting period will be complete
     */
    function requestUncommitWithApprovedCompletor(
        uint64 policyID,
        uint256 shares,
        uint256 newMinBalance,
        address completor
    )
        external
        returns (uint256 uncommitCompleteBlock);

    /**
     * @notice Completes uncommitment of shares after escrow period completion
     * @param policyID The ID of the policy to complete uncommitment from
     * @param shares The amount of shMON shares to complete uncommitment for
     */
    function completeUncommit(uint64 policyID, uint256 shares) external;

    /**
     * @notice Completes uncommitment of shMON, and immediately redeems for MON
     * @param policyID The ID of the policy from which to complete uncommitment of shMON
     * @param shares The amount of shMON to complete uncommitment for and then redeem for MON at the current exchange
     * rate
     * @return assets The amount of MON that was redeemed for the given shMON shares
     */
    function completeUncommitAndRedeem(uint64 policyID, uint256 shares) external returns (uint256 assets);

    /**
     * @notice Completes uncommitment of shMON from one policy and commits it to another policy
     * @param fromPolicyID The ID of the policy to complete uncommitment from
     * @param toPolicyID The ID of the policy to commit shares to
     * @param commitRecipient The address that will own the committed shares
     * @param shares The amount of shMON shares to complete uncommitment for and recommit
     */
    function completeUncommitAndRecommit(
        uint64 fromPolicyID,
        uint64 toPolicyID,
        address commitRecipient,
        uint256 shares
    )
        external;

    /**
     * @notice Completes uncommitment of shares after escrow, using an approval if set
     * @dev Acts on the passed `account`'s balances (not the caller's). Enforces approval:
     *      - Completor: requires `msg.sender` to match the approved completor unless approval uses `address(0)` (open).
     *      - Allowance: decreases the approved shares unless it is `type(uint96).max` (infinite).
     * @param policyID The ID of the policy to complete uncommitment from
     * @param shares The amount of shMON shares to complete uncommitment for
     * @param account The address whose uncommitting will be completed and who receives the shares
     */
    function completeUncommitWithApproval(uint64 policyID, uint256 shares, address account) external;

    /**
     * @notice Sets or overwrites uncommit approval for a policy
     * @dev Overrides any existing approval for the caller and policy. Use `type(uint96).max` for infinite allowance,
     *      and `address(0)` for an open approval (anyone can complete).
     * @param policyID The ID of the policy
     * @param completor The address authorized to complete uncommitment (zero address allows anyone)
     * @param shares The maximum shares that can be completed using this approval
     */
    function setUncommitApproval(uint64 policyID, address completor, uint256 shares) external;

    // --------------------------------------------- //
    //                 Agent Functions               //
    // --------------------------------------------- //

    /**
     * @notice Places a hold on a specific amount of an account's committed shares in a policy
     * @dev Held shares cannot be uncommitted until released
     * @param policyID The ID of the policy
     * @param account The address whose shares will be held
     * @param shares The amount of shares to hold
     */
    function hold(uint64 policyID, address account, uint256 shares) external;

    /**
     * @notice Releases previously held shares for an account in a policy
     * @param policyID The ID of the policy
     * @param account The address whose shares will be released
     * @param shares The amount of shares to release
     */
    function release(uint64 policyID, address account, uint256 shares) external;

    /**
     * @notice Places holds on multiple accounts' committed shares in a policy
     * @param policyID The ID of the policy
     * @param accounts Array of addresses whose shares will be held
     * @param amounts Array of amounts to hold for each account
     */
    function batchHold(uint64 policyID, address[] calldata accounts, uint256[] memory amounts) external;

    /**
     * @notice Releases previously held shares for multiple accounts in a policy
     * @param policyID The ID of the policy
     * @param accounts Array of addresses whose shares will be released
     * @param amounts Array of amounts to release for each account
     */
    function batchRelease(uint64 policyID, address[] calldata accounts, uint256[] calldata amounts) external;

    /**
     * @notice Transfers committed shares from one account to another within the same policy
     * @dev Can handle either shares (shMON) or assets (MON) based on inUnderlying flag
     * @param policyID The ID of the policy
     * @param from The address providing the committed shares
     * @param to The address receiving the committed shares
     * @param amount The amount to transfer (in shares or assets depending on inUnderlying)
     * @param fromReleaseAmount The amount of shares to release from any holds before transferring
     * @param inUnderlying Whether amount is specified in the underlying asset (MON) rather than shares (shMON)
     */
    function agentTransferFromCommitted(
        uint64 policyID,
        address from,
        address to,
        uint256 amount,
        uint256 fromReleaseAmount,
        bool inUnderlying
    )
        external;

    /**
     * @notice Transfers committed shares to an account's uncommitted balance
     * @dev Can handle either shares (shMON) or assets (MON) based on inUnderlying flag
     * @param policyID The ID of the policy
     * @param from The address providing the committed shares
     * @param to The address receiving the uncommitted shares
     * @param amount The amount to transfer (in shares or assets depending on inUnderlying)
     * @param fromReleaseAmount The amount of shares to release from any holds before transferring
     * @param inUnderlying Whether amount is specified in the underlying asset (MON) rather than shares (shMON)
     */
    function agentTransferToUncommitted(
        uint64 policyID,
        address from,
        address to,
        uint256 amount,
        uint256 fromReleaseAmount,
        bool inUnderlying
    )
        external;

    /**
     * @notice Withdraws MON from an account's committed balance to an address
     * @dev Can handle either shares (shMON) or assets (MON) based on inUnderlying flag
     * @param policyID The ID of the policy
     * @param from The address providing the committed shares
     * @param to The address receiving the withdrawn MON
     * @param amount The amount to withdraw (in shares or assets depending on inUnderlying)
     * @param fromReleaseAmount The amount of shares to release from any holds before withdrawing
     * @param inUnderlying Whether amount is specified in the underlying asset (MON) rather than shares (shMON)
     */
    function agentWithdrawFromCommitted(
        uint64 policyID,
        address from,
        address to,
        uint256 amount,
        uint256 fromReleaseAmount,
        bool inUnderlying
    )
        external;

    /**
     * @notice Uses an account's committed shares to boost yield
     * @dev Can handle either shares (shMON) or assets (MON) based on inUnderlying flag
     * @param policyID The ID of the policy
     * @param from The address providing the committed shares
     * @param amount The amount to use for yield boosting (in shares or assets depending on inUnderlying)
     * @param fromReleaseAmount The amount of shares to release from any holds before boosting
     * @param inUnderlying Whether amount is specified in the underlying asset (MON) rather than shares (shMON)
     */
    function agentBoostYieldFromCommitted(
        uint64 policyID,
        address from,
        uint256 amount,
        uint256 fromReleaseAmount,
        bool inUnderlying
    )
        external;

    // --------------------------------------------- //
    //           Top-Up Management Functions         //
    // --------------------------------------------- //

    /**
     * @notice Sets minimum committed balance and top-up settings for an account in a policy
     * @param policyID The ID of the policy
     * @param minCommitted The minimum committed balance to maintain
     * @param maxTopUpPerPeriod The maximum amount to top up per period
     * @param topUpPeriodDuration The duration of the top-up period in blocks
     */
    function setMinCommittedBalance(
        uint64 policyID,
        uint128 minCommitted,
        uint128 maxTopUpPerPeriod,
        uint32 topUpPeriodDuration
    )
        external;

    // --------------------------------------------- //
    //           Policy Management Functions         //
    // --------------------------------------------- //

    /**
     * @notice Creates a new policy with the specified escrow duration
     * @param escrowDuration The duration in blocks for which uncommitting shares must wait before completion
     * @return policyID The ID of the newly created policy
     */
    function createPolicy(uint48 escrowDuration) external returns (uint64 policyID);

    /**
     * @notice Adds a policy agent to the specified policy
     * @param policyID The ID of the policy
     * @param agent The address of the agent to add
     */
    function addPolicyAgent(uint64 policyID, address agent) external;

    /**
     * @notice Removes a policy agent from the specified policy
     * @param policyID The ID of the policy
     * @param agent The address of the agent to remove
     */
    function removePolicyAgent(uint64 policyID, address agent) external;

    /**
     * @notice Disables a policy, preventing new commitments but allowing for uncommitting
     * @dev This action is irreversible. Disabled policies cannot be re-enabled.
     * @param policyID The ID of the policy to disable
     */
    function disablePolicy(uint64 policyID) external;

    // --------------------------------------------- //
    //                 View Functions                //
    // --------------------------------------------- //

    /**
     * @notice Gets the total number of policies created
     * @return The current policy count
     */
    function policyCount() external view returns (uint64);

    /**
     * @notice Gets information about a specific policy
     * @param policyID The ID of the policy to query
     * @return The policy information (escrow duration and active status)
     */
    function getPolicy(uint64 policyID) external view returns (Policy memory);

    /**
     * @notice Checks if an address is an agent for a specific policy
     * @param policyID The ID of the policy
     * @param agent The address to check
     * @return Whether the address is a policy agent
     */
    function isPolicyAgent(uint64 policyID, address agent) external view returns (bool);

    /**
     * @notice Gets all agents for a specific policy
     * @param policyID The ID of the policy
     * @return Array of agent addresses
     */
    function getPolicyAgents(uint64 policyID) external view returns (address[] memory);

    /**
     * @notice Retrieves the rolling global liabilities tracked by StakeTracker
     * @return rewardsPayable The MON amount reserved for rewards payouts
     * @return redemptionsPayable The MON amount pending redemption settlement
     */
    function globalLiabilities()
        external
        view
        returns (uint128 rewardsPayable, uint128 redemptionsPayable, uint128 commissionPayable);

    /**
     * @notice Gets the amount of shares that are held for an account in a policy
     * @param policyID The ID of the policy
     * @param account The address to check
     * @return The amount of shares held
     */
    function getHoldAmount(uint64 policyID, address account) external view returns (uint256);

    /**
     * @notice Gets the block number when uncommitting will be complete for an account in a policy
     * @param policyID The ID of the policy
     * @param account The address to check
     * @return The block number when uncommitting will be complete
     */
    function uncommittingCompleteBlock(uint64 policyID, address account) external view returns (uint256);

    /**
     * @notice Gets the uncommit approval for an account in a policy
     * @param policyID The ID of the policy
     * @param account The address to check
     * @return approval The approval data (completor and shares)
     */
    function getUncommitApproval(
        uint64 policyID,
        address account
    )
        external
        view
        returns (UncommitApproval memory approval);

    /**
     * @notice Gets the committed balance of an account in a policy
     * @param policyID The ID of the policy
     * @param account The address to check
     * @return The committed balance in shares
     */
    function balanceOfCommitted(uint64 policyID, address account) external view returns (uint256);

    /**
     * @notice Gets the uncommitting balance of an account in a policy
     * @param policyID The ID of the policy
     * @param account The address to check
     * @return The uncommitting balance in shares
     */
    function balanceOfUncommitting(uint64 policyID, address account) external view returns (uint256);

    function policyBalanceAvailable(
        uint64 policyID,
        address account,
        bool inUnderlying
    )
        external
        view
        returns (uint256 balanceAvailable);

    function topUpAvailable(
        uint64 policyID,
        address account,
        bool inUnderlying
    )
        external
        view
        returns (uint256 amountAvailable);
}
