// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.37;

import { AccessManaged } from "@openzeppelin/contracts/access/manager/AccessManaged.sol";
import { Pausable } from "@openzeppelin/contracts/utils/Pausable.sol";
import { FixedPointMathLib } from "solady/utils/FixedPointMathLib.sol";
import { IDepot } from "src/depot/IDepot.sol";
import { AddressFreezeList } from "src/AddressFreezeList.sol";
import { TransitAccountLib } from "src/helpers/TransitAccountLib.sol";

/**
 * @title Depot
 * @notice The main ledger for the Transit Terminal system. The Depot exists only on a Hub chain and uses a bytes28
 * "account" data type to store data for different address/chainId combinations.
 * @dev This is a bytes28 to save some bytes for extra metadata if ever necessary. 8 bytes should be plenty for a
 * chainId.
 */
contract Depot is IDepot, AccessManaged, Pausable {

    /// @notice The main ledger of account (address/chainId) to a token (address/chainId) to a balance
    mapping(bytes28 accountId => mapping(bytes28 assetId => uint256)) public balanceOf;

    /// @notice Balance locked for pending requests (e.g. withdrawals). Reservations take effect one epoch after being
    /// made so fills settling in the current epoch are not invalidated mid-epoch. Reservations never expire; only
    /// release frees them.
    mapping(bytes28 accountId => mapping(bytes28 assetId => Reservation)) public reservation;

    /// @notice The current settlement round. A solver increments an epoch on settlement of a batch.
    /// @dev Actions that could invalidate a batch in progress (reservations, requests, non-facilitated cancellations)
    /// take effect at `settlementEpoch + 1`, after the current batch settles, so solvers build against stable state.
    /// If no batch settles for 24h anyone may advance, so pending actions cannot stall. Starts at 1 so 0 can mean
    /// "unset" in epoch-valued mappings (e.g. requestStatus, cancelledFrom).
    uint256 public settlementEpoch;

    /// @notice the timestamp of when settlementEpoch was last incremented
    uint256 public lastEpochAdvancedAt;

    AddressFreezeList public addressFreezeList;

    constructor(address _authority, AddressFreezeList _addressFreezeList) AccessManaged(_authority) {
        settlementEpoch = 1;
        lastEpochAdvancedAt = block.timestamp;
        emit EpochAdvanced(1);
        _setAddressFreezeList(_addressFreezeList);
    }

    function pause() external restricted {
        _pause();
    }

    function unpause() external restricted {
        _unpause();
    }

    function setAddressFreezeList(AddressFreezeList _addressFreezeList) external restricted {
        _setAddressFreezeList(_addressFreezeList);
    }

    // ========================================= LEDGER =========================================

    /// @notice transfer an asset between 2 accounts. This does not use an approval system so is not available for anyone but access gated modules to use. The function will not allow transferring of reserved funds
    function transferFrom(
        bytes28 fromAccountId,
        bytes28 toAccountId,
        bytes28 assetId,
        uint256 amount
    )
        external
        restricted
        whenNotPaused
    {
        if (!TransitAccountLib.isValid(fromAccountId) || !TransitAccountLib.isValid(toAccountId)) revert ZeroAddress();
        _requireNotFrozen(fromAccountId);
        if (balanceOf[fromAccountId][assetId] < _reserved(fromAccountId, assetId) + amount) {
            revert InsufficientBalance();
        }
        _transfer(fromAccountId, toAccountId, assetId, amount);
    }

    function transferAmong(TransferDelta[] calldata deltas) external restricted whenNotPaused {
        bytes28[] memory assetIds = new bytes28[](deltas.length);
        uint256[] memory debits = new uint256[](deltas.length);
        uint256[] memory credits = new uint256[](deltas.length);
        uint256 count;
        for (uint256 i; i < deltas.length; i++) {
            TransferDelta calldata delta = deltas[i];
            bytes28 assetId = delta.assetId;
            uint256 j;
            while (j < count && assetIds[j] != assetId) j++;
            if (j == count) {
                assetIds[j] = assetId;
                count++;
            }
            if (delta.fromAccountId != bytes28(0)) {
                if (!TransitAccountLib.isValid(delta.fromAccountId)) revert ZeroAddress();
                _requireNotFrozen(delta.fromAccountId);
                if (balanceOf[delta.fromAccountId][assetId] < _reserved(delta.fromAccountId, assetId) + delta.amount) {
                    revert InsufficientBalance();
                }
                debits[j] += delta.amount;
            }
            if (delta.toAccountId != bytes28(0)) {
                if (!TransitAccountLib.isValid(delta.toAccountId)) revert ZeroAddress();
                credits[j] += delta.amount;
            }
            _transfer(delta.fromAccountId, delta.toAccountId, assetId, delta.amount);
        }
        for (uint256 j; j < count; j++) {
            if (debits[j] != credits[j]) revert NotZeroSum();
        }
    }

    function mint(bytes28 toAccountId, bytes28 assetId, uint256 amount) external restricted whenNotPaused {
        if (!TransitAccountLib.isValid(toAccountId)) revert ZeroAddress();
        _transfer(bytes28(0), toAccountId, assetId, amount);
    }

    function burn(bytes28 fromAccountId, bytes28 assetId, uint256 amount) external restricted whenNotPaused {
        if (!TransitAccountLib.isValid(fromAccountId)) revert ZeroAddress();
        _requireNotFrozen(fromAccountId);
        if (balanceOf[fromAccountId][assetId] < _reserved(fromAccountId, assetId) + amount) {
            revert InsufficientBalance();
        }
        _transfer(fromAccountId, bytes28(0), assetId, amount);
    }

    function forceTransferFrom(
        bytes28 fromAccountId,
        bytes28 toAccountId,
        bytes28 assetId,
        uint256 amount
    )
        external
        restricted
    {
        if (!TransitAccountLib.isValid(fromAccountId) || !TransitAccountLib.isValid(toAccountId)) revert ZeroAddress();
        _transfer(fromAccountId, toAccountId, assetId, amount);
    }

    function forceBurn(bytes28 fromAccountId, bytes28 assetId, uint256 amount) external restricted {
        if (!TransitAccountLib.isValid(fromAccountId)) revert ZeroAddress();
        _transfer(fromAccountId, bytes28(0), assetId, amount);
    }

    function advanceEpoch(uint256 epoch) external {
        if (block.timestamp < lastEpochAdvancedAt + 24 hours) _checkCanCall(_msgSender(), _msgData());
        if (epoch != settlementEpoch) revert BadEpoch(epoch);
        settlementEpoch = epoch + 1;
        lastEpochAdvancedAt = block.timestamp;
        emit EpochAdvanced(epoch + 1);
    }

    // ========================================= USER =========================================

    /// @notice Reserves `amount` of an account's balance, effective from the next settlement epoch.
    function reserve(bytes28 accountId, bytes28 assetId, uint256 amount) external restricted whenNotPaused {
        uint256 effectiveAtEpoch = settlementEpoch + 1;
        _reserve(accountId, assetId, amount);
        emit Reserved(accountId, assetId, amount, effectiveAtEpoch);
    }

    /// @notice Releases `amount` of an account's effective (has been reserved for >= 1 epoch) reservation.
    /// @dev Reverts on underflow if the amount is not yet effective. Callers only release after the request is
    /// effective.
    function release(bytes28 accountId, bytes28 assetId, uint256 amount) external restricted whenNotPaused {
        _release(accountId, assetId, amount);
        emit Release(accountId, assetId, amount);
    }

    /// @notice Balance not locked by reservations, floored at 0 since forced transfers can bypass reservations.
    function freeBalanceOf(bytes28 accountId, bytes28 assetId) external view returns (uint256) {
        return FixedPointMathLib.zeroFloorSub(balanceOf[accountId][assetId], _reserved(accountId, assetId));
    }

    // ========================================= INTERNAL =========================================

    function _requireNotFrozen(bytes28 accountId) internal view {
        if (addressFreezeList.isFrozen(accountId)) revert AccountFrozen(accountId);
    }

    /// @dev View equivalent of _rollReservation: counts pending as reserved once its epoch has arrived, without
    /// writing.
    function _setAddressFreezeList(AddressFreezeList _addressFreezeList) internal {
        if (address(_addressFreezeList).code.length == 0) revert NoCode();
        addressFreezeList = _addressFreezeList;
        emit AddressFreezeListSet(_addressFreezeList);
    }

    function _reserved(bytes28 accountId, bytes28 assetId) internal view returns (uint256) {
        Reservation storage res = reservation[accountId][assetId];
        if (res.pendingEpoch <= settlementEpoch) return res.effective + res.pending;
        return res.effective;
    }

    /// @dev Rolls first, so any amount still pending shares the same pendingEpoch (always settlementEpoch + 1) and one
    /// pending bucket suffices.
    function _reserve(bytes28 accountId, bytes28 assetId, uint256 amount) internal {
        Reservation storage res = _rollReservation(accountId, assetId);
        res.pending += amount;
        res.pendingEpoch = settlementEpoch + 1;
    }

    /// @dev Only effective amounts can be released; releasing a still-pending amount underflows and reverts.
    function _release(bytes28 accountId, bytes28 assetId, uint256 amount) internal {
        _rollReservation(accountId, assetId).effective -= amount;
    }

    /// @dev Promotes pending into effective once its epoch has arrived. advanceEpoch cannot iterate every
    /// account, so each reservation catches up before its next write.
    function _rollReservation(bytes28 accountId, bytes28 assetId) internal returns (Reservation storage res) {
        res = reservation[accountId][assetId];
        if (res.pendingEpoch <= settlementEpoch) {
            res.effective += res.pending;
            res.pending = 0;
        }
    }

    function _transfer(bytes28 fromAccountId, bytes28 toAccountId, bytes28 assetId, uint256 amount) internal {
        if (fromAccountId != bytes28(0)) balanceOf[fromAccountId][assetId] -= amount;
        if (toAccountId != bytes28(0)) balanceOf[toAccountId][assetId] += amount;
        emit Transfer(msg.sender, fromAccountId, toAccountId, assetId, amount);
    }

}
