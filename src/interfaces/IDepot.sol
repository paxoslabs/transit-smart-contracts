// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.37;

import { AddressFreezeList } from "src/AddressFreezeList.sol";

/// @title Transit Terminal Depot
/// @notice The main ledger for the Transit Terminal system, keyed by bytes28 account and asset ids (chainId and
/// address).
interface IDepot {

    /// @notice An account's reserved balance of one asset.
    /// @param effective Amount currently reserved.
    /// @param pending Amount that becomes reserved once `pendingEpoch` arrives.
    /// @param pendingEpoch Epoch at which `pending` becomes effective.
    struct Reservation {
        uint256 effective;
        uint256 pending;
        uint256 pendingEpoch;
    }

    /// @notice A single movement within a transferAmong batch.
    /// @param fromAccountId Account debited, or zero to mint.
    /// @param toAccountId Account credited, or zero to burn.
    /// @param assetId Asset moved.
    /// @param amount Amount moved.
    struct TransferDelta {
        bytes28 fromAccountId;
        bytes28 toAccountId;
        bytes28 assetId;
        uint256 amount;
    }

    /// @notice A balance moved. A zero `fromAccountId` is a mint and a zero `toAccountId` is a burn.
    /// @param operator Caller that moved the balance.
    /// @param fromAccountId Account debited.
    /// @param toAccountId Account credited.
    /// @param assetId Asset moved.
    /// @param amount Amount moved.
    event Transfer(
        address operator,
        bytes28 indexed fromAccountId,
        bytes28 indexed toAccountId,
        bytes28 indexed assetId,
        uint256 amount
    );

    /// @notice The settlement epoch advanced.
    /// @param epoch New settlement epoch.
    event EpochAdvanced(uint256 epoch);

    /// @notice The AddressFreezeList has been updated.
    /// @param addressFreezeList New AddressFreezeList.
    event AddressFreezeListSet(AddressFreezeList addressFreezeList);

    /// @notice Balance was reserved.
    /// @param accountId Account whose balance is reserved.
    /// @param assetId Asset reserved.
    /// @param amount Amount reserved.
    /// @param effectiveAtEpoch Epoch from which the reservation applies.
    event Reserved(bytes28 indexed accountId, bytes28 indexed assetId, uint256 amount, uint256 effectiveAtEpoch);

    /// @notice A reservation was released.
    /// @param accountId Account whose reservation is released.
    /// @param assetId Asset released.
    /// @param amount Amount released.
    event Release(bytes28 indexed accountId, bytes28 indexed assetId, uint256 amount);

    /// @notice An account id is not a valid chainId and address pair.
    error InvalidAccount();

    /// @notice Unreserved balance is less than the amount debited.
    error InsufficientBalance();

    /// @notice A transferAmong batch's debits and credits do not net to zero for some asset.
    error NotZeroSum();

    /// @notice A TransferDelta has both a zero `fromAccountId` and a zero `toAccountId`.
    error EmptyDelta();

    /// @notice A TransferDelta has a zero amount.
    error ZeroAmount();

    /// @notice An asset id is not a valid chainId and address pair.
    error InvalidAsset();

    /// @notice The debited account is frozen.
    /// @param accountId Frozen account.
    error AccountFrozen(bytes28 accountId);

    /// @notice The address has no code.
    error NoCode();

    /// @notice The main ledger of account (address/chainId) to a token (address/chainId) to a balance.
    /// @param accountId Account to query.
    /// @param assetId Asset to query.
    /// @return Balance, including reserved funds.
    function balanceOf(bytes28 accountId, bytes28 assetId) external view returns (uint256);

    /// @notice Balance reserved for pending requests (e.g. withdrawals). Reservations take effect one epoch after being
    /// made so fills settling in the current epoch are not invalidated mid-epoch. Reservations never expire; only
    /// release frees them.
    /// @param accountId Account to query.
    /// @param assetId Asset to query.
    /// @return effective Amount currently reserved.
    /// @return pending Amount that becomes reserved once `pendingEpoch` arrives.
    /// @return pendingEpoch Epoch at which `pending` becomes effective.
    function reservation(
        bytes28 accountId,
        bytes28 assetId
    )
        external
        view
        returns (uint256 effective, uint256 pending, uint256 pendingEpoch);

    /// @notice Balance not reserved, floored at 0 since forced transfers can bypass reservations.
    /// @param accountId Account to query.
    /// @param assetId Asset to query.
    /// @return Spendable balance.
    function freeBalanceOf(bytes28 accountId, bytes28 assetId) external view returns (uint256);

    /// @notice The current settlement round. A solver increments an epoch on settlement of a batch.
    /// @dev Actions that could invalidate a batch in progress (reservations, requests, non-facilitated cancellations)
    /// take effect at `settlementEpoch + 1`, after the current batch settles, so solvers build against stable state.
    /// If no batch settles for 24h anyone may advance, so pending actions cannot stall. Starts at 1 so 0 can mean
    /// "unset" in epoch-valued mappings (e.g. requestEffectiveAtEpoch, cancelledFrom).
    /// @return Current settlement epoch.
    function settlementEpoch() external view returns (uint256);

    /// @notice The timestamp of when settlementEpoch was last incremented.
    /// @return Timestamp of the last advance.
    function lastEpochAdvancedAt() external view returns (uint256);

    /// @notice Query the AddressFreezeList checked on every debit.
    /// @return AddressFreezeList contract.
    function addressFreezeList() external view returns (AddressFreezeList);

    /// @notice Disable ledger functions in an emergency. forceTransferFrom and advanceEpoch are unaffected.
    function pause() external;

    /// @notice Enable ledger functions.
    function unpause() external;

    /// @notice Set the AddressFreezeList.
    /// @param _addressFreezeList AddressFreezeList contract; must have code.
    function setAddressFreezeList(AddressFreezeList _addressFreezeList) external;

    /// @notice Transfer an asset between 2 accounts. This does not use an approval system so is not available for
    /// anyone but access gated modules to use. The function will not allow transferring of reserved funds.
    /// @param fromAccountId Account debited.
    /// @param toAccountId Account credited.
    /// @param assetId Asset moved.
    /// @param amount Amount moved.
    function transferFrom(bytes28 fromAccountId, bytes28 toAccountId, bytes28 assetId, uint256 amount) external;

    /// @notice Applies a batch of transfers (e.g. a solver settlement) atomically. A delta with a zero `fromAccountId`
    /// mints and one with a zero `toAccountId` burns, but per asset total mints must equal total burns, so the batch
    /// conserves supply. Like transferFrom, debits respect pause, freeze and reservations.
    /// @dev Balance checks run against live balances as each delta applies, so a credit must precede any debit that
    /// relies on it.
    /// @param deltas Movements to apply, in order.
    function transferAmong(TransferDelta[] calldata deltas) external;

    /// @notice Credits a new balance, e.g. on deposit, backed by tokens held in the asset's spoke warehouse.
    /// @dev Frozen recipients may still receive; freeze only restricts outflows.
    /// @param toAccountId Account credited.
    /// @param assetId Asset minted.
    /// @param amount Amount minted.
    function mint(bytes28 toAccountId, bytes28 assetId, uint256 amount) external;

    /// @notice Removes a balance, e.g. on withdrawal, before the asset's spoke warehouse releases the tokens.
    /// Respects pause, freeze and reservations.
    /// @param fromAccountId Account debited.
    /// @param assetId Asset burned.
    /// @param amount Amount burned.
    function burn(bytes28 fromAccountId, bytes28 assetId, uint256 amount) external;

    /// @notice Admin override to move or seize funds, e.g. from a frozen account. Pass a zero `toAccountId` to burn.
    /// @dev Bypasses all checks: pause, freeze, reservations and account validity. Reservations may then exceed the
    /// balance (see freeBalanceOf).
    /// @param fromAccountId Account debited, or zero to mint.
    /// @param toAccountId Account credited, or zero to burn.
    /// @param assetId Asset moved.
    /// @param amount Amount moved.
    function forceTransferFrom(bytes28 fromAccountId, bytes28 toAccountId, bytes28 assetId, uint256 amount) external;

    /// @notice Increments settlementEpoch. Called by settlement conductors after each batch and by DepotTimelock on
    /// execution. Restricted until 24h after the last advance, then callable by anyone so pending actions cannot stall.
    /// @dev Settlers should guard against an advance racing their batch by checking the expected epoch before settling.
    function advanceEpoch() external;

    /// @notice Reserves `amount` of an account's balance, effective from the next settlement epoch.
    /// @param accountId Account whose balance is reserved.
    /// @param assetId Asset reserved.
    /// @param amount Amount reserved.
    function reserve(bytes28 accountId, bytes28 assetId, uint256 amount) external;

    /// @notice Releases `amount` of an account's effective (has been reserved for >= 1 epoch) reservation.
    /// @dev Reverts on underflow if the amount is not yet effective. Callers only release after the request is
    /// effective.
    /// @param accountId Account whose reservation is released.
    /// @param assetId Asset released.
    /// @param amount Amount released.
    function release(bytes28 accountId, bytes28 assetId, uint256 amount) external;

}
