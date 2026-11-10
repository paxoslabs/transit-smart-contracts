// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.37;

import { IMessagingReceiver } from "../messaging/IMessagingReceiver.sol";

interface ITurnstile is IMessagingReceiver {

    enum ActionType {
        Deposit,
        Withdrawal,
        Generic
    }

    enum MessageStatus {
        None,
        Failed,
        Expired,
        Executed
    }

    struct DepositMessage {
        address asset;
        uint256 amount;
        bytes32 toAccountId;
        bytes32 salt;
    }

    struct GenericMessage {
        address sender;
        address target;
        bytes data;
        uint256 deadline;
        bytes32 salt;
    }

    struct WithdrawalMessage {
        address asset;
        uint256 amount;
        address to;
        bytes32 salt;
    }

    struct DepositAction {
        address asset;
        uint256 amount;
        uint64 toChainId;
        uint256 deadline;
        bytes32 salt;
        Permit permit;
    }

    struct Permit {
        uint256 deadline;
        uint8 v;
        bytes32 r;
        bytes32 s;
    }

    struct WithdrawalAction {
        uint64 ownerChainId;
        address owner;
        address to;
        bytes32 assetId;
        uint256 amount;
        uint256 deadline;
        bool partiallyFillable;
        bytes32 salt;
    }

    struct GenericAction {
        address target;
        bytes data;
        uint256 deadline;
        bytes32 salt;
    }

    event Deposit(address indexed asset, address indexed from, bytes32 indexed toAccountId, uint256 amount);
    event MessagingAdapterUpdated(address indexed adapter);
    event HubWarehouseConductorUpdated(address indexed hubWarehouseConductor);
    event MessageFailed(uint64 indexed sourceChainId, ActionType indexed actionType, bytes32 messageHash, bytes body);
    event MessageRetried(uint64 indexed sourceChainId, ActionType indexed actionType, bytes32 messageHash);
    event MessageExpired(uint64 indexed sourceChainId, ActionType indexed actionType, bytes32 messageHash);

    error MessageReplay();
    error UnknownAdapter();
    error OutOfGas();
    error NotRoutable();
    error NotFailed();
    error NoHandler();
    error NoFare();
    error LengthMismatch();
    error FareMismatch();
    error Expired();

    function DEPOSIT_ACTION_TYPEHASH() external view returns (bytes32);

    function PERMIT_TYPEHASH() external view returns (bytes32);

    function WITHDRAWAL_ACTION_TYPEHASH() external view returns (bytes32);

    function GENERIC_ACTION_TYPEHASH() external view returns (bytes32);

    function SPOKE_WAREHOUSE() external view returns (address);

    function messagingAdapter() external view returns (address);

    function hubWarehouseConductor() external view returns (address);

    function messageStatus(bytes32 messageHash) external view returns (MessageStatus);

    function routable(address target, bytes4 selector) external view returns (bool);

    function setMessagingAdapter(address adapter) external;

    function setHubWarehouseConductor(address _hubWarehouseConductor) external;

    function setRoutable(address target, bytes4[] calldata selectors, bool allowed) external;

    function pause() external;

    function unpause() external;

    function dispatch(
        ActionType[] calldata actionTypes,
        bytes[] calldata actionData,
        uint256[] calldata fares,
        uint64[] calldata messageGas
    )
        external
        payable
        returns (bytes32[] memory messageHashes);

    function facilitate(
        ActionType[] calldata actionTypes,
        bytes[] calldata actionData,
        bytes[] calldata signatures,
        uint256[] calldata fares,
        uint64[] calldata messageGas
    )
        external
        payable;

    function hashDepositAction(DepositAction memory action) external view returns (bytes32);

    function hashWithdrawalAction(WithdrawalAction memory action) external view returns (bytes32);

    function hashGenericAction(GenericAction memory action) external view returns (bytes32);

    function digestMessage(uint64 chainId, ActionType actionType, bytes memory body) external pure returns (bytes32);

    function quote(
        ActionType[] calldata actionTypes,
        bytes[] calldata actionData,
        uint64[] calldata messageGas
    )
        external
        view
        returns (uint256[] memory fares);

    function retry(uint64 sourceChainId, ActionType actionType, bytes calldata body) external;

}
