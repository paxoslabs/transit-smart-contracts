// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.37;

interface IDepot {

    struct Reservation {
        uint256 effective;
        uint256 pending;
        uint256 pendingEpoch;
    }

    struct TransferDelta {
        bytes32 fromAccountId;
        bytes32 toAccountId;
        bytes32 assetId;
        uint256 amount;
    }

    event Transfer(
        address operator,
        bytes32 indexed fromAccountId,
        bytes32 indexed toAccountId,
        bytes32 indexed assetId,
        uint256 amount
    );
    event EpochAdvanced(uint256 epoch);
    event Reserved(bytes32 indexed accountId, bytes32 indexed assetId, uint256 amount, uint256 effectiveAtEpoch);

    error ZeroAddress();
    error ChainMismatch(uint64 chainId);
    error BadEpoch(uint256 epoch);
    error InsufficientBalance();
    error NotZeroSum();

    function balanceOf(bytes32 accountId, bytes32 assetId) external view returns (uint256);

    function reservation(
        bytes32 accountId,
        bytes32 assetId
    )
        external
        view
        returns (uint256 effective, uint256 pending, uint256 pendingEpoch);

    function settlementEpoch() external view returns (uint256);

    function lastEpochAdvancedAt() external view returns (uint256);

    function pause() external;

    function unpause() external;

    function transferFrom(bytes32 fromAccountId, bytes32 toAccountId, bytes32 assetId, uint256 amount) external;

    function transferAmong(TransferDelta[] calldata deltas) external;

    function mint(bytes32 toAccountId, bytes32 assetId, uint256 amount) external;

    function burn(bytes32 fromAccountId, bytes32 assetId, uint256 amount) external;

    function advanceEpoch(uint256 epoch) external;

    function reserve(bytes32 accountId, bytes32 assetId, uint256 amount) external;

    function release(bytes32 accountId, bytes32 assetId, uint256 amount) external;

}
