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
        uint256 nonce;
        uint256 amount;
        bytes32 toAccountId;
    }

    struct FacilitatedCall {
        address sender;
        address target;
        bytes data;
        bytes32 feeAssetId;
        uint256 fee;
        uint256 nonce;
        uint256 deadline;
    }

    struct GenericMessage {
        uint256 nonce;
        address sender;
        address target;
        bytes data;
    }

    struct WithdrawalMessage {
        address asset;
        uint256 nonce;
        uint256 amount;
        address to;
    }

    event MessagingAdapterUpdated(address indexed adapter);
    event MessageFailed(
        uint64 indexed sourceChainId, MessageType indexed messageType, bytes32 messageHash, bytes body
    );
    event MessageRetried(uint64 indexed sourceChainId, MessageType indexed messageType, bytes32 messageHash);

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

    function FACILITATED_CALL_TYPEHASH() external view returns (bytes32);

    function HUB() external view returns (address);

    function WAREHOUSE() external view returns (address);

    function messagingAdapter() external view returns (IMessagingAdapter);

    function outboundNonce() external view returns (uint256);

    function messageConsumed(bytes32 messageHash) external view returns (bool);

    function routable(address target, bytes4 selector) external view returns (bool);

    function failed(bytes32 messageHash) external view returns (bool);


    function setMessagingAdapter(IMessagingAdapter adapter) external;

    function setRoutable(address target, bytes4[] calldata selectors, bool allowed) external;

    function pause() external;

    function unpause() external;

    function send(
        uint64 chainId,
        uint64 messageGas,
        MessageType messageType,
        bytes calldata body
    )
        external
        payable
        returns (bytes32 messageId);

    function relay(address target, bytes calldata data, uint64 messageGas) external payable;

    function facilitate(
        FacilitatedCall[] calldata calls,
        bytes[] calldata signatures,
        uint256[] calldata values
    )
        external
        payable;

    function hashFacilitatedCall(FacilitatedCall calldata facilitatedCall) external view returns (bytes32);

    function quote(
        uint64 chainId,
        uint64 messageGas,
        MessageType messageType,
        bytes calldata body
    )
        external
        view
        returns (uint256 fee);

    function retry(uint64 sourceChainId, MessageType messageType, bytes calldata body) external;

}
