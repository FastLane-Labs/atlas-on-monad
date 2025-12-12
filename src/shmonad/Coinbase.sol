//SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.8.28 <0.9.0;

import { SafeTransferLib } from "@solady/utils/SafeTransferLib.sol";
import { SafeCastLib } from "@solady/utils/SafeCastLib.sol";

import { IMonadStaking } from "./interfaces/IMonadStaking.sol";
import { ICoinbase } from "./interfaces/ICoinbase.sol";
import { STAKING, DUST_THRESHOLD, SCALE, TRANSFER_GAS_LIMIT } from "./Constants.sol";

struct CoinbaseConfig {
    address commissionRecipient; // receives validator commission sent in `process()`
    uint96 commissionRate; // as a fraction of 1e18
}

contract Coinbase is ICoinbase {
    using SafeTransferLib for address;
    using SafeCastLib for uint256;

    uint64 public immutable VAL_ID;
    address public immutable SHMONAD;
    address public immutable AUTH_ADDRESS;

    CoinbaseConfig internal s_config;

    error OnlyShMonadCaller();
    error OnlyAuthAddress();
    error InvalidCommissionRate();
    error RecipientCannotBeZeroAddress();
    error ValidatorNotFoundInPrecompile(uint64 validatorId);

    event CommissionRateUpdated(uint256 oldCommissionRate, uint256 newCommissionRate);
    event CommissionRecipientUpdated(address oldRecipient, address newRecipient);

    constructor(uint64 valId) {
        VAL_ID = valId;
        SHMONAD = msg.sender;

        (address _authAddress, uint256 _commissionRate) = _getValidator(valId);

        AUTH_ADDRESS = _authAddress;
        s_config = CoinbaseConfig({ commissionRecipient: _authAddress, commissionRate: _commissionRate.toUint96() });

        emit CommissionRateUpdated(0, _commissionRate);
        emit CommissionRecipientUpdated(address(0), _authAddress);
    }

    receive() external payable { }

    modifier onlyAuthAddress() {
        require(msg.sender == AUTH_ADDRESS, OnlyAuthAddress());
        _;
    }

    modifier onlyShMonad() {
        require(msg.sender == SHMONAD, OnlyShMonadCaller());
        _;
    }

    /// @dev This is called during `_crankValidator()` in ShMonad, so should never revert.
    function process() external onlyShMonad returns (bool success) {
        CoinbaseConfig memory _config = s_config;

        // Assume all balance is accrued priority fees
        uint256 _currentBalance = address(this).balance;

        // Calculate the commission
        uint256 _validatorCommission = _currentBalance * _config.commissionRate / SCALE;
        uint256 _rewardPortion = _currentBalance - _validatorCommission;

        // Don't pay commission unless the remaining reward is large enough to send via externalReward
        if (_rewardPortion < DUST_THRESHOLD) return false;
        if (_validatorCommission > 0) {
            bool _success = _config.commissionRecipient.trySafeTransferETH(_validatorCommission, TRANSFER_GAS_LIMIT);
            if (!_success) return false;
        }
        return _sendRewards(VAL_ID, _rewardPortion);
    }

    function updateCommissionRate(uint256 newCommissionRate) external onlyAuthAddress {
        require(newCommissionRate <= SCALE, InvalidCommissionRate());

        uint256 _oldCommissionRate = s_config.commissionRate;
        s_config.commissionRate = newCommissionRate.toUint96();

        emit CommissionRateUpdated(_oldCommissionRate, newCommissionRate);
    }

    function updateCommissionRateFromStakingConfig() external onlyAuthAddress {
        (, uint256 _newCommissionRate) = _getValidator(VAL_ID);

        uint256 _oldCommissionRate = s_config.commissionRate;
        s_config.commissionRate = _newCommissionRate.toUint96();

        emit CommissionRateUpdated(_oldCommissionRate, _newCommissionRate);
    }

    function updateCommissionRecipient(address newRecipient) external onlyAuthAddress {
        require(newRecipient != address(0), RecipientCannotBeZeroAddress());
        address _oldRecipient = s_config.commissionRecipient;
        s_config.commissionRecipient = newRecipient;

        emit CommissionRecipientUpdated(_oldRecipient, newRecipient);
    }

    function getCommissionRate() external view returns (uint256) {
        return s_config.commissionRate;
    }

    function getCommissionRecipient() external view returns (address) {
        return s_config.commissionRecipient;
    }

    function _inEpochDelayPeriod() internal returns (bool) {
        (, bool _isInEpochDelayPeriod) = STAKING.getEpoch();
        return _isInEpochDelayPeriod;
    }

    function _sendRewards(uint64 validatorId, uint256 rewardAmount) internal returns (bool) {
        try STAKING.externalReward{ value: rewardAmount }(validatorId) returns (bool _precompileSuccess) {
            return _precompileSuccess;
        } catch {
            return false;
        }
    }

    function _getValidator(uint64 validatorId) internal returns (address authAddress, uint256 commissionRate) {
        // Note: Real precompile returns zeros for missing, mock reverts with UnknownValidator()
        try STAKING.getValidator(validatorId) returns (
            address _authAddress,
            uint64,
            uint256,
            uint256,
            uint256,
            uint256,
            uint256,
            uint256 _consensusCommissionRate,
            uint256,
            uint256 _snapshotCommissionRate,
            bytes memory,
            bytes memory
        ) {
            authAddress = _authAddress;
            commissionRate = _inEpochDelayPeriod() ? _snapshotCommissionRate : _consensusCommissionRate;
        } catch { }
        require(authAddress != address(0), ValidatorNotFoundInPrecompile(validatorId));
    }
}
