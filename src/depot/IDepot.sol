// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.37;

interface IDepot {

    struct Reservation {
        uint256 effective;
        uint256 pending;
        uint256 pendingEpoch;
    }

    struct TransferDelta {
        bytes28 fromAccountId;
        bytes28 toAccountId;
        bytes28 assetId;
        uint256 amount;
    }

    event Transfer(
        address operator,
        bytes28 indexed fromAccountId,
        bytes28 indexed toAccountId,
        bytes28 indexed assetId,
        uint256 amount
    );
    event EpochAdvanced(uint256 epoch);
    event Reserved(bytes28 indexed accountId, bytes28 indexed assetId, uint256 amount, uint256 effectiveAtEpoch);
    event Release(bytes28 indexed accountId, bytes28 indexed assetId, uint256 amount);

    /// TODO: Consider renaming to InvalidAccount; now thrown when TransitAccountLib.isValid fails, not only on zero.
    error ZeroAddress();
    error BadEpoch(uint256 epoch);
    error InsufficientBalance();
    error NotZeroSum();
    error AccountFrozen(bytes28 accountId);

    function balanceOf(bytes28 accountId, bytes28 assetId) external view returns (uint256);

    function reservation(
        bytes28 accountId,
        bytes28 assetId
    )
        external
        view
        returns (uint256 effective, uint256 pending, uint256 pendingEpoch);

    function freeBalanceOf(bytes28 accountId, bytes28 assetId) external view returns (uint256);

    function settlementEpoch() external view returns (uint256);

    function lastEpochAdvancedAt() external view returns (uint256);

    function transitPolice() external view returns (address);

    function pause() external;

    function unpause() external;

    function setTransitPolice(address _transitPolice) external;

    function transferFrom(bytes28 fromAccountId, bytes28 toAccountId, bytes28 assetId, uint256 amount) external;

    function priorityTransferFrom(bytes28 fromAccountId, bytes28 toAccountId, bytes28 assetId, uint256 amount) external;

    function transferAmong(TransferDelta[] calldata deltas) external;

    function mint(bytes28 toAccountId, bytes28 assetId, uint256 amount) external;

    function burn(bytes28 fromAccountId, bytes28 assetId, uint256 amount) external;

    function forceTransferFrom(bytes28 fromAccountId, bytes28 toAccountId, bytes28 assetId, uint256 amount) external;

    function forceBurn(bytes28 fromAccountId, bytes28 assetId, uint256 amount) external;

    function advanceEpoch(uint256 epoch) external;

    function reserve(bytes28 accountId, bytes28 assetId, uint256 amount) external;

    function release(bytes28 accountId, bytes28 assetId, uint256 amount) external;

}
