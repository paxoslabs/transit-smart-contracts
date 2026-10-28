// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.37;

import { AccessManaged } from "@openzeppelin/contracts/access/manager/AccessManaged.sol";
import { Pausable } from "@openzeppelin/contracts/utils/Pausable.sol";
import { ECDSA } from "solady/utils/ECDSA.sol";
import { EIP712 } from "solady/utils/EIP712.sol";
import { ITurnstile } from "./ITurnstile.sol";
import { UserTerminal } from "./terminal/UserTerminal.sol";
import { Warehouse } from "./Warehouse.sol";
import { TransitTokenLib } from "./helpers/TransitTokenLib.sol";
import { IMessagingAdapter } from "./messaging/IMessagingAdapter.sol";

contract Turnstile is AccessManaged, Pausable, EIP712, ITurnstile {

    bytes32 public constant CALL_TYPEHASH = keccak256("Call(address target,bytes data)");

    bytes32 public constant GENERIC_MESSAGE_TYPEHASH = keccak256(
        "GenericMessage(address sender,Call[] calls,uint256 nonce,uint256 deadline)Call(address target,bytes data)"
    );

    address public immutable WAREHOUSE;

    IMessagingAdapter public messagingAdapter;
    address public userTerminal;
    uint256 public outboundNonce;

    mapping(bytes32 messageHash => bool) public messageConsumed;
    mapping(address target => mapping(bytes4 selector => bool)) public routable;
    mapping(bytes32 messageHash => bool) public failed;

    constructor(address _authority, address _warehouse) AccessManaged(_authority) {
        WAREHOUSE = _warehouse;
    }

    function _domainNameAndVersion() internal pure override returns (string memory, string memory) {
        return ("Transit Turnstile", "1");
    }

    // ========================================= ADMIN =========================================

    function setMessagingAdapter(IMessagingAdapter adapter) external restricted {
        messagingAdapter = adapter;
        emit MessagingAdapterUpdated(address(adapter));
    }

    function setUserTerminal(address _userTerminal) external restricted {
        userTerminal = _userTerminal;
        emit UserTerminalUpdated(_userTerminal);
    }

    function setRoutable(address target, bytes4[] calldata selectors, bool allowed) external restricted {
        for (uint256 i; i < selectors.length; i++) {
            routable[target][selectors[i]] = allowed;
        }
    }

    function pause() external restricted {
        _pause();
    }

    function unpause() external restricted {
        _unpause();
    }

    function sendDepositMessage(
        uint64 chainId,
        uint64 messageGas,
        address asset,
        uint256 amount,
        bytes32 toAccountId
    )
        external
        payable
        restricted
        returns (bytes32 messageId)
    {
        _requireNotPaused();
        messageId = _sendMessage(
            chainId,
            messageGas,
            MessageType.Deposit,
            abi.encode(DepositMessage({ asset: asset, nonce: ++outboundNonce, amount: amount, toAccountId: toAccountId }))
        );
    }

    function sendWithdrawalMessage(
        uint64 chainId,
        uint64 messageGas,
        address asset,
        uint256 amount,
        address to
    )
        external
        payable
        restricted
        returns (bytes32 messageId)
    {
        _requireNotPaused();
        messageId = _sendMessage(
            chainId,
            messageGas,
            MessageType.Withdrawal,
            abi.encode(WithdrawalMessage({ asset: asset, nonce: ++outboundNonce, amount: amount, to: to }))
        );
    }

    function sendGenericMessage(Call[] calldata calls, uint256 deadline, uint64 messageGas) external payable {
        _requireNotPaused();
        IMessagingAdapter adapter = messagingAdapter;
        if (address(adapter) == address(0)) revert UnknownAdapter();
        _sendMessage(
            adapter.HUB_CHAIN_ID(),
            messageGas,
            MessageType.Generic,
            abi.encode(GenericMessage({ sender: msg.sender, calls: calls, nonce: ++outboundNonce, deadline: deadline }))
        );
    }

    function facilitate(
        GenericMessage[] calldata calls,
        bytes[] calldata signatures,
        uint256[][] calldata values
    )
        external
        payable
        restricted
    {
        _requireNotPaused();
        if (calls.length != signatures.length || calls.length != values.length) revert LengthMismatch();
        for (uint256 i; i < calls.length; i++) {
            GenericMessage calldata message = calls[i];
            if (block.timestamp > message.deadline) revert Expired();
            if (message.calls.length != values[i].length) revert LengthMismatch();
            bytes32 digest = hashGenericMessage(message);
            if (ECDSA.recoverCalldata(digest, signatures[i]) != message.sender) revert BadSignature();
            _consume(digestMessage(uint64(block.chainid), MessageType.Generic, abi.encode(message)));
            bytes32 senderAccountId = TransitTokenLib.formatFacilitatedAccountId(
                TransitTokenLib.formatAccountId(uint64(block.chainid), message.sender)
            );
            _executeCalls(message.calls, values[i], senderAccountId);
        }
    }

    function executeCalls(Call[] calldata calls, bytes32 accountId) external {
        if (msg.sender != address(this)) revert NotSelf();
        _executeCalls(calls, new uint256[](calls.length), accountId);
    }

    function hashGenericMessage(GenericMessage calldata message) public view returns (bytes32) {
        bytes32[] memory callHashes = new bytes32[](message.calls.length);
        for (uint256 i; i < callHashes.length; i++) {
            Call calldata facilitated = message.calls[i];
            callHashes[i] = keccak256(abi.encode(CALL_TYPEHASH, facilitated.target, keccak256(facilitated.data)));
        }
        return _hashTypedData(
            keccak256(
                abi.encode(
                    GENERIC_MESSAGE_TYPEHASH,
                    message.sender,
                    keccak256(abi.encodePacked(callHashes)),
                    message.nonce,
                    message.deadline
                )
            )
        );
    }

    function digestMessage(uint64 chainId, MessageType messageType, bytes memory body) public pure returns (bytes32) {
        return keccak256(abi.encode(chainId, messageType, body));
    }

    function quoteDepositMessage(
        uint64 chainId,
        uint64 messageGas,
        address asset,
        uint256 amount,
        bytes32 toAccountId
    )
        external
        view
        returns (uint256 fee)
    {
        return _quote(
            chainId,
            messageGas,
            MessageType.Deposit,
            abi.encode(DepositMessage({ asset: asset, nonce: outboundNonce + 1, amount: amount, toAccountId: toAccountId }))
        );
    }

    function quoteWithdrawalMessage(
        uint64 chainId,
        uint64 messageGas,
        address asset,
        uint256 amount,
        address to
    )
        external
        view
        returns (uint256 fee)
    {
        return _quote(
            chainId,
            messageGas,
            MessageType.Withdrawal,
            abi.encode(WithdrawalMessage({ asset: asset, nonce: outboundNonce + 1, amount: amount, to: to }))
        );
    }

    function quoteGenericMessage(
        Call[] calldata calls,
        uint256 deadline,
        uint64 messageGas
    )
        external
        view
        returns (uint256 fee)
    {
        IMessagingAdapter adapter = messagingAdapter;
        if (address(adapter) == address(0)) revert UnknownAdapter();
        return _quote(
            adapter.HUB_CHAIN_ID(),
            messageGas,
            MessageType.Generic,
            abi.encode(GenericMessage({ sender: msg.sender, calls: calls, nonce: outboundNonce + 1, deadline: deadline }))
        );
    }

    function retry(uint64 sourceChainId, MessageType messageType, bytes calldata body) external restricted {
        _requireNotPaused();
        bytes32 messageHash = digestMessage(sourceChainId, messageType, body);
        if (!failed[messageHash]) revert NotFailed();
        delete failed[messageHash];
        emit MessageRetried(sourceChainId, messageType, messageHash);
        _execute(sourceChainId, messageType, body);
    }

    // ========================================= ADAPTER ========================================

    function receiveMessage(uint64 chainId, bytes calldata payload) external restricted {
        (MessageType messageType, bytes memory body) = abi.decode(payload, (MessageType, bytes));
        _handleMessage(chainId, messageType, body);
    }

    function _sendMessage(
        uint64 chainId,
        uint64 messageGas,
        MessageType messageType,
        bytes memory body
    )
        internal
        returns (bytes32 messageId)
    {
        if (chainId == block.chainid) {
            if (msg.value != 0) revert NoFee();
            messageId = keccak256(abi.encode(messageType, body));
            _handleMessage(chainId, messageType, body);
        } else {
            IMessagingAdapter adapter = messagingAdapter;
            if (address(adapter) == address(0)) revert UnknownAdapter();
            messageId = adapter.send{ value: msg.value }(chainId, messageGas, abi.encode(messageType, body));
        }
    }

    function _quote(
        uint64 chainId,
        uint64 messageGas,
        MessageType messageType,
        bytes memory body
    )
        internal
        view
        returns (uint256)
    {
        if (chainId == block.chainid) return 0;
        return messagingAdapter.quote(chainId, messageGas, abi.encode(messageType, body));
    }

    function _handleMessage(uint64 chainId, MessageType messageType, bytes memory body) internal {
        _requireNotPaused();
        _consume(digestMessage(chainId, messageType, body));
        _execute(chainId, messageType, body);
    }

    function _consume(bytes32 messageHash) internal {
        // A revert here leaves the delivery failed in the bridge's queue forever; it is never retried successfully.
        if (messageConsumed[messageHash]) revert MessageReplay();
        messageConsumed[messageHash] = true;
    }

    function _executeCalls(Call[] memory calls, uint256[] memory values, bytes32 accountId) internal {
        for (uint256 i; i < calls.length; i++) {
            if (!routable[calls[i].target][bytes4(calls[i].data)]) revert NotRoutable();
            (bool ok, bytes memory result) =
                calls[i].target.call{ value: values[i] }(abi.encodePacked(calls[i].data, accountId));
            if (!ok) {
                assembly {
                    revert(add(result, 0x20), mload(result))
                }
            }
        }
    }

    function _execute(uint64 sourceChainId, MessageType messageType, bytes memory body) internal {
        bool ok;
        bytes memory result;
        uint256 gasBefore;
        if (messageType == MessageType.Deposit) {
            if (userTerminal == address(0)) revert NoHandler();
            DepositMessage memory message = abi.decode(body, (DepositMessage));
            gasBefore = gasleft();
            (ok, result) = userTerminal.call(abi.encodeCall(UserTerminal.receiveDeposit, (sourceChainId, message.asset, message.amount, message.toAccountId)));
        } else if (messageType == MessageType.Withdrawal) {
            if (WAREHOUSE == address(0)) revert NoHandler();
            WithdrawalMessage memory message = abi.decode(body, (WithdrawalMessage));
            gasBefore = gasleft();
            (ok, result) = WAREHOUSE.call(abi.encodeCall(Warehouse.receiveWithdrawal, (message.asset, message.amount, message.to)));
        } else {
            GenericMessage memory message = abi.decode(body, (GenericMessage));
            if (block.timestamp > message.deadline) {
                if (sourceChainId == block.chainid) revert Expired();
                emit MessageExpired(sourceChainId, messageType, digestMessage(sourceChainId, messageType, body));
                return;
            }
            gasBefore = gasleft();
            (ok, result) = address(this).call(
                abi.encodeCall(this.executeCalls, (message.calls, TransitTokenLib.formatAccountId(sourceChainId, message.sender)))
            );
        }
        if (ok) return;
        if (sourceChainId == block.chainid) {
            assembly {
                revert(add(result, 0x20), mload(result))
            }
        }
        if (gasleft() <= gasBefore / 63) revert OutOfGas();
        bytes32 messageHash = digestMessage(sourceChainId, messageType, body);
        failed[messageHash] = true;
        emit MessageFailed(sourceChainId, messageType, messageHash, body);
    }

}
