// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.37;

import { AccessManaged } from "@openzeppelin/contracts/access/manager/AccessManaged.sol";
import { Pausable } from "@openzeppelin/contracts/utils/Pausable.sol";
import { FixedPointMathLib } from "solady/utils/FixedPointMathLib.sol";
import { IDepot } from "src/depot/IDepot.sol";
import { TransitPolice } from "src/TransitPolice.sol";
import { TransitAccountLib } from "src/helpers/TransitAccountLib.sol";

contract Depot is IDepot, AccessManaged, Pausable {

    mapping(bytes28 accountId => mapping(bytes28 assetId => uint256)) public balanceOf;

    mapping(bytes28 accountId => mapping(bytes28 assetId => Reservation)) public reservation;

    uint256 public settlementEpoch;
    uint256 public lastEpochAdvancedAt;

    address public transitPolice;

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

    function setTransitPolice(address _transitPolice) external restricted {
        transitPolice = _transitPolice;
    }

    // ========================================= LEDGER =========================================

    function transferFrom(
        bytes28 fromAccountId,
        bytes28 toAccountId,
        bytes28 assetId,
        uint256 amount
    )
        external
        restricted
    {
        _requireNotPaused();
        if (!TransitAccountLib.isValid(fromAccountId) || !TransitAccountLib.isValid(toAccountId)) revert ZeroAddress();
        _requireNotFrozen(fromAccountId);
        if (balanceOf[fromAccountId][assetId] < _reserved(fromAccountId, assetId) + amount) {
            revert InsufficientBalance();
        }
        _transfer(fromAccountId, toAccountId, assetId, amount);
    }

    function priorityTransferFrom(
        bytes28 fromAccountId,
        bytes28 toAccountId,
        bytes28 assetId,
        uint256 amount
    )
        external
        restricted
    {
        _requireNotPaused();
        if (!TransitAccountLib.isValid(fromAccountId) || !TransitAccountLib.isValid(toAccountId)) revert ZeroAddress();
        _requireNotFrozen(fromAccountId);
        _transfer(fromAccountId, toAccountId, assetId, amount);
    }

    function transferAmong(TransferDelta[] calldata deltas) external restricted {
        _requireNotPaused();
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

    function mint(bytes28 toAccountId, bytes28 assetId, uint256 amount) external restricted {
        _requireNotPaused();
        if (!TransitAccountLib.isValid(toAccountId)) revert ZeroAddress();
        _transfer(bytes28(0), toAccountId, assetId, amount);
    }

    function burn(bytes28 fromAccountId, bytes28 assetId, uint256 amount) external restricted {
        _requireNotPaused();
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

    function reserve(bytes28 accountId, bytes28 assetId, uint256 amount) external restricted {
        _requireNotPaused();
        uint256 effectiveAtEpoch = settlementEpoch + 1;
        _reserve(accountId, assetId, amount);
        emit Reserved(accountId, assetId, amount, effectiveAtEpoch);
    }

    function release(bytes28 accountId, bytes28 assetId, uint256 amount) external restricted {
        _requireNotPaused();
        _release(accountId, assetId, amount);
        emit Release(accountId, assetId, amount);
    }

    function freeBalanceOf(bytes28 accountId, bytes28 assetId) external view returns (uint256) {
        return FixedPointMathLib.zeroFloorSub(balanceOf[accountId][assetId], _reserved(accountId, assetId));
    }

    // ========================================= INTERNAL =========================================

    function _requireNotFrozen(bytes28 accountId) internal view {
        // Check is skipped if transitPolice is unset.
        if (transitPolice == address(0)) return;
        if (TransitPolice(transitPolice).isFrozen(accountId)) revert AccountFrozen(accountId);
    }

    function _reserved(bytes28 accountId, bytes28 assetId) internal view returns (uint256) {
        Reservation storage res = reservation[accountId][assetId];
        if (res.pendingEpoch <= settlementEpoch) return res.effective + res.pending;
        return res.effective;
    }

    function _reserve(bytes28 accountId, bytes28 assetId, uint256 amount) internal {
        Reservation storage res = _rollReservation(accountId, assetId);
        res.pending += amount;
        res.pendingEpoch = settlementEpoch + 1;
    }

    function _release(bytes28 accountId, bytes28 assetId, uint256 amount) internal {
        _rollReservation(accountId, assetId).effective -= amount;
    }

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
