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

    /// @notice transfer an asset between 2 accounts. This does not use an approval system so is not available for
    /// anyone but access gated modules to use. The function will not allow transferring of reserved funds
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
        if (!TransitAccountLib.isValid(fromAccountId) || !TransitAccountLib.isValid(toAccountId)) {
            revert InvalidAccount();
        }
        _requireNotFrozen(fromAccountId);
        if (balanceOf[fromAccountId][assetId] < _reserved(fromAccountId, assetId) + amount) {
            revert InsufficientBalance();
        }
        _transfer(fromAccountId, toAccountId, assetId, amount);
    }

    /// @notice Applies a batch of transfers (e.g. a solver settlement) atomically. A delta with a zero `fromAccountId`
    /// mints and one with a zero `toAccountId` burns, but per asset total mints must equal total burns, so the batch
    /// conserves supply. Like transferFrom, debits respect pause, freeze and reservations.
    /// @dev Balance checks run against live balances as each delta applies, so a credit must precede any debit that
    /// relies on it.
    function transferAmong(TransferDelta[] calldata deltas) external restricted whenNotPaused {
        bytes28[] memory assetIds = new bytes28[](deltas.length);
        uint256[] memory debits = new uint256[](deltas.length);
        uint256[] memory credits = new uint256[](deltas.length);
        uint256 uniqueAssetCount;

        // Loop through the provided deltas
        for (uint256 deltaIndex; deltaIndex < deltas.length; deltaIndex++) {
            TransferDelta calldata delta = deltas[deltaIndex];
            if (delta.fromAccountId == bytes28(0) && delta.toAccountId == bytes28(0)) revert EmptyDelta();
            if (delta.amount == 0) revert ZeroAmount();

            bytes28 assetId = delta.assetId;
            if (!TransitAccountLib.isValid(assetId)) revert InvalidAsset();
            uint256 assetIndex;

            /// TODO: Linear search is O(deltas * uniqueAssets). Could require solvers to order inputs so conductors
            /// emit deltas grouped by ascending assetId, then net-check each group in one pass with no arrays.
            // loop through assetIds and find the index of this deltas asset or insert it
            while (assetIndex < uniqueAssetCount && assetIds[assetIndex] != assetId) assetIndex++;
            if (assetIndex == uniqueAssetCount) {
                assetIds[assetIndex] = assetId;
                uniqueAssetCount++;
            }

            // bytes28(0) represents an intent to mint so the following applies to all non-mints
            if (delta.fromAccountId != bytes28(0)) {
                // Ensure the account is valid and from is not from a frozen address
                if (!TransitAccountLib.isValid(delta.fromAccountId)) revert InvalidAccount();
                _requireNotFrozen(delta.fromAccountId);
                // Ensure enough balance exists at the account unreserved at this point
                if (balanceOf[delta.fromAccountId][assetId] < _reserved(delta.fromAccountId, assetId) + delta.amount) {
                    revert InsufficientBalance();
                }
                // increment debits at the index of this assetId
                debits[assetIndex] += delta.amount;
            }

            // bytes28(0) represents an intent to burn so the following applies to all non-burns
            if (delta.toAccountId != bytes28(0)) {
                // Ensure the account is valid
                if (!TransitAccountLib.isValid(delta.toAccountId)) revert InvalidAccount();
                credits[assetIndex] += delta.amount;
            }

            _transfer(delta.fromAccountId, delta.toAccountId, assetId, delta.amount);
        }

        // Loop through the credits and debits to ensure they are equal. This protects against malicious solvers, tokens
        // cannot be sent if they are not taken from somewhere. This check combined with enforcing users signed limits
        // is what ensures that users are never allocated too little or too much on the ledger
        for (uint256 assetIndex; assetIndex < uniqueAssetCount; assetIndex++) {
            if (debits[assetIndex] != credits[assetIndex]) revert NotZeroSum();
        }
    }

    /// @notice Credits a new balance, e.g. on deposit, backed by tokens locked in the asset's spoke warehouse.
    /// @dev Frozen recipients may still receive; freeze only restricts outflows.
    function mint(bytes28 toAccountId, bytes28 assetId, uint256 amount) external restricted whenNotPaused {
        if (!TransitAccountLib.isValid(toAccountId)) revert InvalidAccount();
        if (!TransitAccountLib.isValid(assetId)) revert InvalidAsset();
        _transfer(bytes28(0), toAccountId, assetId, amount);
    }

    /// @notice Removes a balance, e.g. on withdrawal, before the asset's spoke warehouse releases the tokens.
    /// Respects pause, freeze and reservations.
    function burn(bytes28 fromAccountId, bytes28 assetId, uint256 amount) external restricted whenNotPaused {
        if (!TransitAccountLib.isValid(fromAccountId)) revert InvalidAccount();
        _requireNotFrozen(fromAccountId);
        if (balanceOf[fromAccountId][assetId] < _reserved(fromAccountId, assetId) + amount) {
            revert InsufficientBalance();
        }
        _transfer(fromAccountId, bytes28(0), assetId, amount);
    }

    /// @notice Admin override to move or seize funds, e.g. from a frozen account. Pass a zero `toAccountId` to burn.
    /// @dev Bypasses all checks: pause, freeze, reservations and account validity. Reservations may then exceed the
    /// balance (see freeBalanceOf).
    function forceTransferFrom(
        bytes28 fromAccountId,
        bytes28 toAccountId,
        bytes28 assetId,
        uint256 amount
    )
        external
        restricted
    {
        _transfer(fromAccountId, toAccountId, assetId, amount);
    }

    /// @notice Increments settlementEpoch. Called by settlement conductors after each batch and by DepotTimelock on
    /// execution. Restricted until 24h after the last advance, then callable by anyone so pending actions cannot stall.
    /// @dev Settlers should guard against an advance racing their batch by checking the expected epoch before settling.
    function advanceEpoch() external {
        if (block.timestamp < lastEpochAdvancedAt + 24 hours) _checkCanCall(_msgSender(), _msgData());
        unchecked {
            ++settlementEpoch;
        }
        lastEpochAdvancedAt = block.timestamp;
        emit EpochAdvanced(settlementEpoch);
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

    function _setAddressFreezeList(AddressFreezeList _addressFreezeList) internal {
        if (address(_addressFreezeList).code.length == 0) revert NoCode();
        addressFreezeList = _addressFreezeList;
        emit AddressFreezeListSet(_addressFreezeList);
    }

    /// @dev View equivalent of _rollReservation: counts pending as reserved once its epoch has arrived, without
    /// writing.
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

    /// @dev Moves a balance with no checks. A zero `fromAccountId` mints and a zero `toAccountId` burns, mirroring
    /// ERC20 `_update`. Callers enforce all validation.
    function _transfer(bytes28 fromAccountId, bytes28 toAccountId, bytes28 assetId, uint256 amount) internal {
        if (fromAccountId != bytes28(0)) balanceOf[fromAccountId][assetId] -= amount;
        if (toAccountId != bytes28(0)) balanceOf[toAccountId][assetId] += amount;
        emit Transfer(msg.sender, fromAccountId, toAccountId, assetId, amount);
    }

}
