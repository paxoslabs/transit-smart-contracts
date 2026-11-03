// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.37;

import { IMessagingAdapter } from "./messaging/IMessagingAdapter.sol";
import { IMessagingReceiver } from "./messaging/IMessagingReceiver.sol";

interface ITurnstile is IMessagingReceiver {

    enum MessageType {
        Deposit,
        Withdrawal,
        Generic
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

    event MessagingAdapterUpdated(address indexed adapter);
    event HubWarehouseTerminalUpdated(address indexed hubWarehouseTerminal);
    event MessageFailed(
        uint64 indexed sourceChainId, MessageType indexed messageType, bytes32 messageHash, bytes body
    );
    event MessageRetried(uint64 indexed sourceChainId, MessageType indexed messageType, bytes32 messageHash);
    event MessageExpired(uint64 indexed sourceChainId, MessageType indexed messageType, bytes32 messageHash);

    error MessageReplay();
    error UnknownAdapter();
    error OutOfGas();
    error NotRoutable();
    error NotFailed();
    error NoHandler();
    error NoFee();
    error LengthMismatch();
    error Expired();
    error BadSignature();

    function GENERIC_MESSAGE_TYPEHASH() external view returns (bytes32);

    function SPOKE_WAREHOUSE_TERMINAL() external view returns (address);

    function messagingAdapter() external view returns (IMessagingAdapter);

    function hubWarehouseTerminal() external view returns (address);

    function outboundNonce() external view returns (uint256);

    function messageConsumed(bytes32 messageHash) external view returns (bool);

    function routable(address target, bytes4 selector) external view returns (bool);

    function failed(bytes32 messageHash) external view returns (bool);


    function setMessagingAdapter(IMessagingAdapter adapter) external;

    function setHubWarehouseTerminal(address _hubWarehouseTerminal) external;

    function setRoutable(address target, bytes4[] calldata selectors, bool allowed) external;

    function pause() external;

    function unpause() external;

    function sendDepositMessage(
        uint64 chainId,
        uint64 messageGas,
        address asset,
        uint256 amount,
        bytes32 toAccountId
    )
        external
        payable
        returns (bytes32 messageId);

    function sendWithdrawalMessage(
        uint64 chainId,
        uint64 messageGas,
        address asset,
        uint256 amount,
        address to
    )
        external
        payable
        returns (bytes32 messageId);

    function sendGenericMessage(address target, bytes calldata data, uint256 deadline, uint64 messageGas, bytes32 salt) external payable;

    function facilitate(
        GenericMessage[] calldata calls,
        bytes[] calldata signatures,
        uint256[] calldata values
    )
        external
        payable;

    function hashGenericMessage(GenericMessage calldata message) external view returns (bytes32);

    function digestMessage(uint64 chainId, MessageType messageType, bytes memory body) external pure returns (bytes32);

    function quoteDepositMessage(
        uint64 chainId,
        uint64 messageGas,
        address asset,
        uint256 amount,
        bytes32 toAccountId
    )
        external
        view
        returns (uint256 fee);

    function quoteWithdrawalMessage(
        uint64 chainId,
        uint64 messageGas,
        address asset,
        uint256 amount,
        address to
    )
        external
        view
        returns (uint256 fee);

    function quoteGenericMessage(
        address target,
        bytes calldata data,
        uint256 deadline,
        uint64 messageGas,
        bytes32 salt
    )
        external
        view
        returns (uint256 fee);

    function retry(uint64 sourceChainId, MessageType messageType, bytes calldata body) external;

}
