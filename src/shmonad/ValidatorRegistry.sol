//SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.8.28 <0.9.0;

import { FixedPointMathLib as Math } from "@solady/utils/FixedPointMathLib.sol";
import { SafeTransferLib } from "@solady/utils/SafeTransferLib.sol";
import { SafeCastLib } from "@solady/utils/SafeCastLib.sol";

// import { TestnetHarness } from "./testnet/TestnetHarness.sol";
import { FastLaneERC4626 } from "./FLERC4626.sol";
import { Coinbase } from "./Coinbase.sol";

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
    AdminValues
} from "./Types.sol";
import { StorageLib } from "./libraries/StorageLib.sol";
import { IMonadStaking } from "./interfaces/IMonadStaking.sol";
import {
    MIN_VALIDATOR_DEPOSIT,
    SCALE,
    TARGET_FLOAT,
    STAKING,
    SHMONAD_VALIDATOR_DEACTIVATION_PERIOD,
    FLOAT_PLACEHOLDER,
    BPS_SCALE,
    EPOCHS_TRACKED,
    UNKNOWN_VAL_ID,
    UNKNOWN_VAL_ADDRESS,
    LAST_VAL_ADDRESS,
    FIRST_VAL_ADDRESS,
    COINBASE_SALT
} from "./Constants.sol";

abstract contract ValidatorRegistry is FastLaneERC4626 {
    using Math for uint256;
    using SafeTransferLib for address;
    using SafeCastLib for uint256;
    using StorageLib for CashFlows;
    using StorageLib for StakingEscrow;
    using StorageLib for PendingBoost;

    // ================================================== //
    //                    Admin Functions                 //
    // ================================================== //

    // Queue up a deactivation
    // NOTE: Takes 5 epochs to complete
    function deactivateValidator(uint64 validatorId) external virtual onlyOwner {
        _beginDeactivatingValidator(validatorId);
    }

    /// @notice Adds a validator and primes its epoch windows without affecting ordering.
    /// @dev Validates existence via precompile (except UNKNOWN placeholder during init).
    /// Inserts at tail of the crank linked list; enforces one id ↔ one coinbase mapping.
    /// Reverts if attempting to reuse sentinel addresses or if validator not fully removed.
    function addValidator(uint64 validatorId, address coinbase) external virtual onlyOwner {
        require(validatorId != UNKNOWN_VAL_ID, InvalidValidatorId(validatorId));
        _addValidator(validatorId, coinbase);
    }

    function addValidator(uint64 validatorId) external virtual onlyOwner returns (address coinbase) {
        require(validatorId != UNKNOWN_VAL_ID, InvalidValidatorId(validatorId));
        coinbase = _deployOrGetCoinbaseContractAddress(validatorId);
        _addValidator(validatorId, coinbase);
    }

    function updateStakingCommission(uint16 feeInBps) external virtual onlyOwner {
        require(feeInBps < BPS_SCALE, CommissionMustBeBelow100Percent());
        s_admin.stakingCommission = feeInBps;
    }

    function updateBoostCommission(uint16 feeInBps) external virtual onlyOwner {
        require(feeInBps < BPS_SCALE, CommissionMustBeBelow100Percent());
        s_admin.boostCommissionRate = feeInBps;
    }

    function updateIncentiveAlignmentPercentage(uint16 percentageInBps) external virtual onlyOwner {
        require(percentageInBps < BPS_SCALE, PercentageMustBeBelow100Percent());
        s_admin.incentiveAlignmentPercentage = percentageInBps;
    }

    function setFrozenStatus(bool isFrozen) external virtual onlyOwner {
        globalEpochPtr_N(0).frozen = isFrozen;
    }

    function setClosedStatus(bool isClosed) external virtual onlyOwner {
        globalEpochPtr_N(0).closed = isClosed;
    }

    function claimAdminCommissionAsShares(uint256 assets, address recipient) external onlyOwner {
        AdminValues memory _admin = s_admin;
        require(_admin.commissionPayable >= assets, InsufficientAccumulatedCommission(assets, _admin.commissionPayable));

        // Instead of depositing new assets, we decrease commissionPayable, which decreases total liabilities. Thus
        // there is still an increase in totalEquity that is commensurate with the increase in totalSupply caused by new
        // shares minted below.
        _admin.commissionPayable -= uint128(assets);

        // Logic below is similar to standard `deposit()` logic, but bypasseses maxDeposit and msg.value checks.
        // `false` indicates that msg.value should not be deducted from total assets before calculating shares. Recent
        // revenue will also not be deducted from total assets.
        uint256 shares = _previewDeposit(assets, false);
        _mint(recipient, shares);

        // NOTE: `_accountForDeposit()` not called, as no new assets are being deposited

        // Persist AdminValues changes to storage
        s_admin = _admin;

        // Transfer event emitted by _mint(). Deposit event, plus a custom event to track admin commission conversions,
        // emitted here.
        emit Deposit(msg.sender, recipient, assets, shares);
        emit AdminCommissionClaimedAsShares(recipient, assets, shares);
    }

    function _addValidator(uint64 validatorId, address coinbase) internal {
        require(validatorId != 0, InvalidValidatorId(validatorId));
        require(coinbase != LAST_VAL_ADDRESS && coinbase != FIRST_VAL_ADDRESS, InvalidValidatorAddress(coinbase));
        require(
            !s_validatorIsActive[UNKNOWN_VAL_ID] || coinbase != UNKNOWN_VAL_ADDRESS, InvalidValidatorAddress(coinbase)
        );

        // Verify validator exists in precompile (unless it's the UNKNOWN_VAL_ID placeholder used during init)
        // Public entry points explicitly reject UNKNOWN_VAL_ID, so it can only reach here during initialization
        if (validatorId != UNKNOWN_VAL_ID) {
            // Note: Real precompile returns zeros for missing, mock reverts with UnknownValidator()
            try STAKING.getValidator(validatorId) returns (
                address authAddress,
                uint64,
                uint256,
                uint256,
                uint256,
                uint256,
                uint256,
                uint256,
                uint256,
                uint256,
                bytes memory,
                bytes memory
            ) {
                require(authAddress != address(0), ValidatorNotFoundInPrecompile(validatorId));
            } catch {
                revert ValidatorNotFoundInPrecompile(validatorId);
            }
        }

        // Disallow re-adding an active validator
        if (s_validatorIsActive[validatorId]) revert ValidatorAlreadyAdded();

        // If the coinbase is already linked:
        // - to a different validatorId: treat as already added
        // - to the same validatorId: treat as not fully removed
        uint64 _existingForCoinbase = s_valIdByCoinbase[coinbase];
        if (_existingForCoinbase != 0) {
            if (_existingForCoinbase == validatorId) revert ValidatorNotFullyRemoved();
            revert ValidatorAlreadyAdded();
        }

        ++s_activeValidatorCount;

        // Validator must be fully removed (which takes a min of SHMONAD_VALIDATOR_DEACTIVATION_PERIOD from when
        // deactivation is initiated) before they can be added again.
        for (uint256 i; i < EPOCHS_TRACKED; i++) {
            if (s_validatorEpoch[validatorId][i].epoch != 0) revert ValidatorNotFullyRemoved();
        }

        s_validatorIsActive[validatorId] = true;
        s_validatorData[validatorId].isActive = true;
        _linkValidatorCoinbase(validatorId, coinbase);

        uint64 _currentEpoch = s_admin.internalEpoch;

        // Initialize s_validatorEpoch for the new validator
        _setEpochStorage(
            validatorEpochPtr_N(1, validatorId),
            Epoch({
                epoch: _currentEpoch + 1,
                withdrawalId: 1,
                hasWithdrawal: false,
                hasDeposit: false,
                crankedInBoundaryPeriod: false,
                wasCranked: false,
                frozen: false,
                closed: false,
                targetStakeAmount: 0
            })
        );

        _setEpochStorage(
            validatorEpochPtr_N(0, validatorId),
            Epoch({
                epoch: _currentEpoch,
                withdrawalId: 1,
                hasWithdrawal: false,
                hasDeposit: false,
                crankedInBoundaryPeriod: false,
                wasCranked: true,
                frozen: false,
                closed: false,
                targetStakeAmount: 0
            })
        );

        if (_currentEpoch > 0) --_currentEpoch;

        _setEpochStorage(
            validatorEpochPtr_N(-1, validatorId),
            Epoch({
                epoch: _currentEpoch,
                withdrawalId: 1,
                hasWithdrawal: false,
                hasDeposit: false,
                crankedInBoundaryPeriod: false,
                wasCranked: true,
                frozen: false,
                closed: false,
                targetStakeAmount: 0
            })
        );

        if (_currentEpoch > 0) --_currentEpoch;

        _setEpochStorage(
            validatorEpochPtr_N(-2, validatorId),
            Epoch({
                epoch: _currentEpoch,
                withdrawalId: 1,
                hasWithdrawal: false,
                hasDeposit: false,
                crankedInBoundaryPeriod: false,
                wasCranked: true,
                frozen: false,
                closed: false,
                targetStakeAmount: 0
            })
        );

        if (_currentEpoch > 0) --_currentEpoch;

        _setEpochStorage(
            validatorEpochPtr_N(-3, validatorId),
            Epoch({
                epoch: _currentEpoch,
                withdrawalId: 1,
                hasWithdrawal: false,
                hasDeposit: false,
                crankedInBoundaryPeriod: false,
                wasCranked: true,
                frozen: false,
                closed: false,
                targetStakeAmount: 0
            })
        );

        validatorRewardsPtr_N(0, validatorId).clear();
        validatorRewardsPtr_N(1, validatorId).clear();

        validatorPendingPtr_N(0, validatorId).clear();
        validatorPendingPtr_N(1, validatorId).clear();

        // Update the link pointers
        _addValidatorToCrankSequence(coinbase);

        emit ValidatorAdded(validatorId, coinbase);
    }

    function _markValidatorNotInActiveSet(uint64 valId, uint256 detectionIndex) internal {
        s_validatorData[valId].inActiveSet_Current = false;
        emit ValidatorNotFoundInActiveSet(valId, s_valCoinbases[valId], globalEpochPtr_N(0).epoch, detectionIndex);
    }

    function _beginDeactivatingValidator(uint64 validatorId) internal {
        address _coinbase = s_valCoinbases[validatorId];
        require(s_validatorData[validatorId].isActive, ValidatorDeactivationNotQueued());

        --s_activeValidatorCount;
        s_validatorData[validatorId].isActive = false;
        s_validatorData[validatorId].epoch = s_admin.internalEpoch;
        emit ValidatorMarkedInactive(validatorId, _coinbase, s_admin.internalEpoch);
    }

    function _completeDeactivatingValidator(uint64 validatorId) internal virtual {
        require(s_validatorIsActive[validatorId], ValidatorAlreadyDeactivated());

        address _coinbase = s_valCoinbases[validatorId];

        // validator deactivation queue takes five epochs
        require(!s_validatorData[validatorId].isActive, ValidatorDeactivationNotQueued());
        require(
            s_admin.internalEpoch >= s_validatorData[validatorId].epoch + SHMONAD_VALIDATOR_DEACTIVATION_PERIOD,
            ValidatorDeactivationQueuedIncomplete()
        );

        // Setting this enables future reactivation
        validatorEpochPtr_N(0, validatorId).epoch = 0;

        delete s_validatorIsActive[validatorId];
        _unlinkValidatorCoinbase(validatorId);
        delete s_validatorData[validatorId];

        // Remove this validator from the link and connect together the validators on either end
        _removeValidatorFromCrankSequence(_coinbase);

        for (uint256 i; i < EPOCHS_TRACKED; i++) {
            delete s_validatorEpoch[validatorId][i];
            delete s_validatorRewards[validatorId][i];
            delete s_validatorPending[validatorId][i];
        }

        // Reset eligibility tracking
        s_valEligibility[validatorId] = 1;

        emit ValidatorDeactivated(validatorId);
    }

    function _removeValidatorFromCrankSequence(address coinbase) internal {
        address _nextValidator = s_valLinkNext[coinbase];
        address _previousValidator = s_valLinkPrevious[coinbase];

        s_valLinkNext[_previousValidator] = _nextValidator;
        s_valLinkPrevious[_nextValidator] = _previousValidator;
    }

    function _addValidatorToCrankSequence(address coinbase) internal {
        address _previousTailValidator = s_valLinkPrevious[LAST_VAL_ADDRESS];
        s_valLinkNext[_previousTailValidator] = coinbase;
        s_valLinkPrevious[coinbase] = _previousTailValidator;
        s_valLinkNext[coinbase] = LAST_VAL_ADDRESS;
        s_valLinkPrevious[LAST_VAL_ADDRESS] = coinbase;
    }

    function _updateSelfRegEligibility(uint64 valId) internal {
        uint64 _internalEpoch = s_admin.internalEpoch;
        if (s_valEligibility[valId] < _internalEpoch) s_valEligibility[valId] = _internalEpoch;
    }

    function denullifyEligibilityMap(uint64[] calldata valIds) public {
        uint256 _length = valIds.length;
        for (uint256 i; i < _length; i++) {
            if (s_valEligibility[valIds[i]] == 0) s_valEligibility[valIds[i]] = 1;
        }
    }

    // ================================================== //
    //          validatorId <-> block.coinbase map        //
    // ================================================== //

    /// @dev Establishes 1:1 link between `valId` and `coinbase`. Reverts if either already linked.
    /// Invariant after success: `s_valCoinbases[valId] == coinbase` and `s_validatorData[coinbase].id == valId`.
    function _linkValidatorCoinbase(uint64 valId, address coinbase) internal {
        if (coinbase == address(0)) revert ZeroAddress();
        if (s_valCoinbases[valId] != address(0) || s_valIdByCoinbase[coinbase] > 0) revert ValidatorAlreadyAdded();

        s_valCoinbases[valId] = coinbase;
        s_valIdByCoinbase[coinbase] = valId;
    }

    /// @dev Clears 1:1 link between `valId` and its existing `coinbase`, if any.
    /// Invariant after success: `s_valCoinbases[valId] == address(0)` and `s_validatorData[coinbase].id == 0`.
    function _unlinkValidatorCoinbase(uint64 valId) internal {
        address _coinbase = s_valCoinbases[valId];
        if (_coinbase != address(0)) {
            delete s_valIdByCoinbase[_coinbase];
            delete s_valCoinbases[valId];
        }
    }

    function _validatorCoinbase(uint64 valId) internal view returns (address) {
        return s_valCoinbases[valId];
    }

    function _getValidatorData(uint64 valId) internal view returns (ValidatorData memory) {
        ValidatorDataStorage memory _validatorData = s_validatorData[valId];
        address coinbase = s_valCoinbases[valId];
        return ValidatorData({
            epoch: _validatorData.epoch,
            id: valId,
            isPlaceholder: valId == UNKNOWN_VAL_ID,
            isActive: _validatorData.isActive,
            inActiveSet_Current: _validatorData.inActiveSet_Current,
            inActiveSet_Last: _validatorData.inActiveSet_Last,
            coinbase: coinbase
        });
    }

    // ================================================== //
    //             Coinbase Deployment Helpers            //
    // ================================================== //

    function _coinbaseSalt(uint64 validatorId) internal pure returns (bytes32) {
        // Domain-separated salt for safety across potential future CREATE2 usages.
        return keccak256(abi.encodePacked(COINBASE_SALT, validatorId));
    }

    function _predictCreate2Address(bytes32 salt, bytes32 initCodeHash) internal view returns (address predicted) {
        // address = keccak256(0xff ++ deployer ++ salt ++ keccak256(init_code))[12:]
        predicted =
            address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, initCodeHash)))));
    }

    function _coinbaseInitCode(uint64 validatorId) internal pure returns (bytes memory) {
        return abi.encodePacked(type(Coinbase).creationCode, abi.encode(validatorId));
    }

    function _coinbaseInitCodeHash(uint64 validatorId) internal pure returns (bytes32) {
        return keccak256(_coinbaseInitCode(validatorId));
    }

    function _predictCoinbaseAddress(uint64 validatorId) internal view returns (address) {
        return _predictCreate2Address(_coinbaseSalt(validatorId), _coinbaseInitCodeHash(validatorId));
    }

    function _deployOrGetCoinbaseContractAddress(uint64 validatorId) internal returns (address coinbase) {
        bytes32 salt = _coinbaseSalt(validatorId);
        bytes memory creationCode = _coinbaseInitCode(validatorId);
        address predicted = _predictCoinbaseAddress(validatorId);
        if (predicted.code.length == 0) {
            address deployed;
            assembly ("memory-safe") {
                deployed := create2(0, add(creationCode, 0x20), mload(creationCode), salt)
            }
            coinbase = deployed;
            require(coinbase != address(0), Create2Failed());
        } else {
            coinbase = predicted;
        }
    }

    // ================================================== //
    //                   View Functions                   //
    // ================================================== //

    /// @notice Returns the deterministic Coinbase address for a validator without deploying it.
    /// @dev Reverts for invalid placeholders to mirror addValidator checks.
    function previewCoinbaseAddress(uint64 validatorId) external view returns (address predicted) {
        require(validatorId != 0 && validatorId != UNKNOWN_VAL_ID, InvalidValidatorId(validatorId));
        predicted = _predictCoinbaseAddress(validatorId);
    }

    function getValidatorStats(uint64 validatorId) external view returns (ValidatorStats memory stats) {
        address coinbase = s_valCoinbases[validatorId];
        stats.isActive = s_validatorData[validatorId].isActive;
        require(stats.isActive || coinbase != address(0), InvalidValidatorId(validatorId));

        Epoch memory _validatorEpoch = validatorEpochPtr_N(-1, validatorId);
        PendingBoost memory _rewardsLast = validatorRewardsPtr_N(-1, validatorId);
        PendingBoost memory _rewardsCurrent = validatorRewardsPtr_N(0, validatorId);

        stats.coinbase = coinbase;
        stats.lastEpoch = _validatorEpoch.epoch;
        stats.targetStakeAmount = _validatorEpoch.targetStakeAmount;
        stats.rewardsPayableLast = _rewardsLast.rewardsPayable;
        stats.earnedRevenueLast = _rewardsLast.earnedRevenue;
        stats.rewardsPayableCurrent = _rewardsCurrent.rewardsPayable;
        stats.earnedRevenueCurrent = _rewardsCurrent.earnedRevenue;
    }

    function isValidatorActive(uint64 validatorId) external view returns (bool) {
        return s_validatorIsActive[validatorId];
    }

    /// @notice Mirrors precompile epoch; startBlock not provided by precompile → returns 0.
    function getEpochInfo() external returns (uint256 epochNumber, uint256 epochStartBlock) {
        (uint64 e,) = STAKING.getEpoch();
        return (uint256(e), 0);
    }

    function getValidatorCoinbase(uint256 validatorId) external view returns (address) {
        return _validatorCoinbase(validatorId.toUint64());
    }

    function getValidatorIdForCoinbase(address coinbase) external view returns (uint256) {
        return s_valIdByCoinbase[coinbase];
    }

    function _validatorIdForCoinbase(address coinbase) internal view override returns (uint64) {
        return s_valIdByCoinbase[coinbase];
    }

    /// @notice Returns the last epoch at which the given validator ID was marked eligible via self-registration
    function getEligibilityEpoch(uint64 valId) external view returns (uint64) {
        return s_valEligibility[valId];
    }

    /// @notice Returns detailed validator data (no structs) for a validatorId.
    function getValidatorData(uint64 validatorId)
        external
        view
        returns (
            uint64 epoch,
            uint64 id,
            bool isPlaceholder,
            bool isActive,
            bool inActiveSet_Current,
            bool inActiveSet_Last,
            address coinbase
        )
    {
        ValidatorData memory _validatorData = _getValidatorData(validatorId);
        return (
            _validatorData.epoch,
            _validatorData.id,
            _validatorData.isPlaceholder,
            _validatorData.isActive,
            _validatorData.inActiveSet_Current,
            _validatorData.inActiveSet_Last,
            _validatorData.coinbase
        );
    }

    /// @notice Returns the active validator set as parallel arrays of ids and coinbases.
    function listActiveValidators() external view returns (uint64[] memory validatorIds, address[] memory coinbases) {
        uint256 count = s_activeValidatorCount;
        validatorIds = new uint64[](count);
        coinbases = new address[](count);
        address cursor = s_valLinkNext[FIRST_VAL_ADDRESS];
        uint256 i;
        while (cursor != LAST_VAL_ADDRESS && i < count) {
            if (cursor != UNKNOWN_VAL_ADDRESS) {
                uint64 valId = s_valIdByCoinbase[cursor];
                if (valId != 0 && s_validatorData[valId].isActive) {
                    validatorIds[i] = valId;
                    coinbases[i] = cursor;
                    unchecked {
                        ++i;
                    }
                }
            }
            cursor = s_valLinkNext[cursor];
        }
    }

    /// @notice Returns last and current epoch values for a validator.
    function getValidatorEpochs(uint64 validatorId)
        external
        view
        returns (uint64 lastEpoch, uint128 lastTargetStakeAmount, uint64 currentEpoch, uint128 currentTargetStakeAmount)
    {
        Epoch memory _last = validatorEpochPtr_N(-1, validatorId);
        Epoch memory _current = validatorEpochPtr_N(0, validatorId);
        return (_last.epoch, _last.targetStakeAmount, _current.epoch, _current.targetStakeAmount);
    }

    /// @notice Returns last and current pending escrow values for a validator.
    function getValidatorPendingEscrow(uint64 validatorId)
        external
        view
        returns (
            uint120 lastPendingStaking,
            uint120 lastPendingUnstaking,
            uint120 currentPendingStaking,
            uint120 currentPendingUnstaking
        )
    {
        StakingEscrow memory _last = validatorPendingPtr_N(-1, validatorId);
        StakingEscrow memory _current = validatorPendingPtr_N(0, validatorId);
        return (_last.pendingStaking, _last.pendingUnstaking, _current.pendingStaking, _current.pendingUnstaking);
    }

    /// @notice Returns last and current rewards tracking for a validator.
    function getValidatorRewards(uint64 validatorId)
        external
        view
        returns (
            uint120 lastRewardsPayable,
            uint120 lastEarnedRevenue,
            uint120 currentRewardsPayable,
            uint120 currentEarnedRevenue
        )
    {
        PendingBoost memory _last = validatorRewardsPtr_N(-1, validatorId);
        PendingBoost memory _current = validatorRewardsPtr_N(0, validatorId);
        return (_last.rewardsPayable, _last.earnedRevenue, _current.rewardsPayable, _current.earnedRevenue);
    }

    /// @notice Returns crank linked-list neighbors for a validator (previous, next).
    function getValidatorNeighbors(uint64 validatorId) external view returns (address previous, address next) {
        address _coinbase = s_valCoinbases[validatorId];
        return (s_valLinkPrevious[_coinbase], s_valLinkNext[_coinbase]);
    }

    /// @notice Returns active validator count.
    function getActiveValidatorCount() external view returns (uint256) {
        return s_activeValidatorCount;
    }

    /// @notice Returns next validator scheduled to crank.
    function getNextValidatorToCrank() external view returns (address) {
        return s_nextValidatorToCrank;
    }
}
