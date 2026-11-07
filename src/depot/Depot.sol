// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.37;

import { AccessManaged } from "@openzeppelin/contracts/access/manager/AccessManaged.sol";
import { Pausable } from "@openzeppelin/contracts/utils/Pausable.sol";
import { IDepot } from "./IDepot.sol";

contract Depot is IDepot, AccessManaged, Pausable {

    mapping(bytes32 accountId => mapping(bytes32 assetId => uint256)) public balanceOf;

    mapping(bytes32 accountId => mapping(bytes32 assetId => Reservation)) public reservation;

    uint256 public settlementEpoch;
    uint256 public lastEpochAdvancedAt;

    constructor(address _authority) AccessManaged(_authority) {
        settlementEpoch = 1;
        lastEpochAdvancedAt = block.timestamp;
    }

    function pause() external restricted {
        _pause();
    }

    function unpause() external restricted {
        _unpause();
    }

    // ========================================= LEDGER =========================================

    function transferFrom(
        bytes32 fromAccountId,
        bytes32 toAccountId,
        bytes32 assetId,
        uint256 amount
    )
        external
        restricted
    {
        _requireNotPaused();
        if (fromAccountId == bytes32(0) || toAccountId == bytes32(0)) revert ZeroAddress();
        if (balanceOf[fromAccountId][assetId] < _reserved(fromAccountId, assetId) + amount) {
            revert InsufficientBalance();
        }
        _transfer(fromAccountId, toAccountId, assetId, amount);
    }

    function transferAmong(TransferDelta[] calldata deltas) external restricted {
        _requireNotPaused();
        bytes32[] memory assetIds = new bytes32[](deltas.length);
        uint256[] memory debits = new uint256[](deltas.length);
        uint256[] memory credits = new uint256[](deltas.length);
        uint256 count;
        for (uint256 i; i < deltas.length; i++) {
            TransferDelta calldata delta = deltas[i];
            bytes32 assetId = delta.assetId;
            uint256 j;
            while (j < count && assetIds[j] != assetId) j++;
            if (j == count) {
                assetIds[j] = assetId;
                count++;
            }
            if (delta.fromAccountId != bytes32(0)) {
                if (balanceOf[delta.fromAccountId][assetId] < _reserved(delta.fromAccountId, assetId) + delta.amount) {
                    revert InsufficientBalance();
                }
                debits[j] += delta.amount;
            }
            if (delta.toAccountId != bytes32(0)) credits[j] += delta.amount;
            _transfer(delta.fromAccountId, delta.toAccountId, assetId, delta.amount);
        }
        for (uint256 j; j < count; j++) {
            if (debits[j] != credits[j]) revert NotZeroSum();
        }
    }

    function mint(bytes32 toAccountId, bytes32 assetId, uint256 amount) external restricted {
        _requireNotPaused();
        if (toAccountId == bytes32(0)) revert ZeroAddress();
        _transfer(bytes32(0), toAccountId, assetId, amount);
    }

    function burn(bytes32 fromAccountId, bytes32 assetId, uint256 amount) external restricted {
        _requireNotPaused();
        if (fromAccountId == bytes32(0)) revert ZeroAddress();
        if (balanceOf[fromAccountId][assetId] < _reserved(fromAccountId, assetId) + amount) {
            revert InsufficientBalance();
        }
        _transfer(fromAccountId, bytes32(0), assetId, amount);
    }

    function advanceEpoch(uint256 epoch) external {
        if (block.timestamp < lastEpochAdvancedAt + 24 hours) _checkCanCall(_msgSender(), _msgData());
        if (epoch != settlementEpoch) revert BadEpoch(epoch);
        settlementEpoch = epoch + 1;
        lastEpochAdvancedAt = block.timestamp;
        emit EpochAdvanced(epoch + 1);
    }

    // ========================================= USER =========================================

    function reserve(bytes32 accountId, bytes32 assetId, uint256 amount) external restricted {
        _requireNotPaused();
        uint256 effectiveAtEpoch = settlementEpoch + 1;
        _reserve(accountId, assetId, amount);
        emit Reserved(accountId, assetId, amount, effectiveAtEpoch);
    }

    function release(bytes32 accountId, bytes32 assetId, uint256 amount) external restricted {
        _requireNotPaused();
        _release(accountId, assetId, amount);
        emit Release(accountId, assetId, amount);
    }

    // ========================================= INTERNAL =========================================

    function _reserved(bytes32 accountId, bytes32 assetId) internal view returns (uint256) {
        Reservation storage res = reservation[accountId][assetId];
        if (res.pendingEpoch <= settlementEpoch) return res.effective + res.pending;
        return res.effective;
    }

    function _reserve(bytes32 accountId, bytes32 assetId, uint256 amount) internal {
        Reservation storage res = _rollReservation(accountId, assetId);
        res.pending += amount;
        res.pendingEpoch = settlementEpoch + 1;
    }

    function _release(bytes32 accountId, bytes32 assetId, uint256 amount) internal {
        _rollReservation(accountId, assetId).effective -= amount;
    }

    function _rollReservation(bytes32 accountId, bytes32 assetId) internal returns (Reservation storage res) {
        res = reservation[accountId][assetId];
        if (res.pendingEpoch <= settlementEpoch) {
            res.effective += res.pending;
            res.pending = 0;
        }
    }

    function _transfer(bytes32 fromAccountId, bytes32 toAccountId, bytes32 assetId, uint256 amount) internal {
        if (fromAccountId != bytes32(0)) balanceOf[fromAccountId][assetId] -= amount;
        if (toAccountId != bytes32(0)) balanceOf[toAccountId][assetId] += amount;
        emit Transfer(msg.sender, fromAccountId, toAccountId, assetId, amount);
    }

}
