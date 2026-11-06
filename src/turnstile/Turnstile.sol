// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.37;

import { AccessManaged } from "@openzeppelin/contracts/access/manager/AccessManaged.sol";
import { Pausable } from "@openzeppelin/contracts/utils/Pausable.sol";
import { ECDSA } from "solady/utils/ECDSA.sol";
import { EIP712 } from "solady/utils/EIP712.sol";
import { ITurnstile } from "./ITurnstile.sol";
import { HubWarehouseConductor } from "../conductor/HubWarehouseConductor.sol";
import { SpokeWarehouse } from "../SpokeWarehouse.sol";
import { TransitTokenLib } from "../helpers/TransitTokenLib.sol";
import { IMessagingAdapter } from "../messaging/IMessagingAdapter.sol";

contract Turnstile is AccessManaged, Pausable, EIP712, ITurnstile {

    bytes32 public constant GENERIC_MESSAGE_TYPEHASH =
        keccak256("GenericMessage(address sender,address target,bytes data,uint256 deadline,bytes32 salt)");

    address public immutable SPOKE_WAREHOUSE;

    address public messagingAdapter;
    address public hubWarehouseConductor;
    uint256 public outboundNonce;

    mapping(bytes32 messageHash => MessageStatus) public messageStatus;
    mapping(address target => mapping(bytes4 selector => bool)) public routable;

    constructor(address _authority, address _spokeWarehouse) AccessManaged(_authority) {
        SPOKE_WAREHOUSE = _spokeWarehouse;
    }

    function _domainNameAndVersion() internal pure override returns (string memory, string memory) {
        return ("Transit Turnstile", "1");
    }

    // ========================================= ADMIN =========================================

    function setMessagingAdapter(address adapter) external restricted {
        messagingAdapter = adapter;
        emit MessagingAdapterUpdated(adapter);
    }

    function setHubWarehouseConductor(address _hubWarehouseConductor) external restricted {
        hubWarehouseConductor = _hubWarehouseConductor;
        emit HubWarehouseConductorUpdated(_hubWarehouseConductor);
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

    function deposit(
        address asset,
        uint256 amount,
        uint64 toChainId,
        address to,
        uint64 messageGas
    )
        external
        payable
        returns (bytes32 messageHash)
    {
        SpokeWarehouse(SPOKE_WAREHOUSE).custody(msg.sender, asset, amount);
        messageHash = _sendDepositMessage(asset, amount, toChainId, to, messageGas);
    }

    function depositWithPermit(
        address asset,
        uint256 amount,
        uint64 toChainId,
        address to,
        uint64 messageGas,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    )
        external
        payable
        returns (bytes32 messageHash)
    {
        SpokeWarehouse(SPOKE_WAREHOUSE).custodyWithPermit(msg.sender, asset, amount, deadline, v, r, s);
        messageHash = _sendDepositMessage(asset, amount, toChainId, to, messageGas);
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
        returns (bytes32 messageHash)
    {
        _requireNotPaused();
        messageHash = _sendMessage(
            chainId,
            messageGas,
            MessageType.Withdrawal,
            abi.encode(WithdrawalMessage({ asset: asset, amount: amount, to: to, salt: bytes32(++outboundNonce) }))
        );
    }

    function sendGenericMessage(
        address target,
        bytes calldata data,
        uint256 deadline,
        uint64 messageGas,
        bytes32 salt
    )
        external
        payable
        returns (bytes32 messageHash)
    {
        _requireNotPaused();
        address adapter = messagingAdapter;
        if (adapter == address(0)) revert UnknownAdapter();
        messageHash = _sendMessage(
            IMessagingAdapter(adapter).HUB_CHAIN_ID(),
            messageGas,
            MessageType.Generic,
            abi.encode(
                GenericMessage({ sender: msg.sender, target: target, data: data, deadline: deadline, salt: salt })
            )
        );
    }

    /// TODO: Decide how facilitate charges fees; a fee call can no longer be bundled with the facilitated call.
    function facilitate(
        GenericMessage[] calldata calls,
        bytes[] calldata signatures,
        uint256[] calldata values
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
            bytes32 digest = hashGenericMessage(message);
            if (ECDSA.recoverCalldata(digest, signatures[i]) != message.sender) revert BadSignature();
            bytes32 messageHash = digestMessage(uint64(block.chainid), MessageType.Generic, abi.encode(message));
            if (messageStatus[messageHash] != MessageStatus.None) revert MessageReplay();
            messageStatus[messageHash] = MessageStatus.Executed;
            bytes32 senderAccountId = TransitTokenLib.formatFacilitatedAccountId(
                TransitTokenLib.formatAccountId(uint64(block.chainid), message.sender)
            );
            (bool ok, bytes memory result) = _executeCall(message.target, message.data, values[i], senderAccountId);
            if (!ok) {
                assembly {
                    revert(add(result, 0x20), mload(result))
                }
            }
        }
    }

    function hashGenericMessage(GenericMessage calldata message) public view returns (bytes32) {
        return _hashTypedData(
            keccak256(
                abi.encode(
                    GENERIC_MESSAGE_TYPEHASH,
                    message.sender,
                    message.target,
                    keccak256(message.data),
                    message.deadline,
                    message.salt
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
            abi.encode(
                DepositMessage({
                    asset: asset, amount: amount, toAccountId: toAccountId, salt: bytes32(outboundNonce + 1)
                })
            )
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
            abi.encode(WithdrawalMessage({ asset: asset, amount: amount, to: to, salt: bytes32(outboundNonce + 1) }))
        );
    }

    function quoteGenericMessage(
        address target,
        bytes calldata data,
        uint256 deadline,
        uint64 messageGas,
        bytes32 salt
    )
        external
        view
        returns (uint256 fee)
    {
        address adapter = messagingAdapter;
        if (adapter == address(0)) revert UnknownAdapter();
        return _quote(
            IMessagingAdapter(adapter).HUB_CHAIN_ID(),
            messageGas,
            MessageType.Generic,
            abi.encode(
                GenericMessage({ sender: msg.sender, target: target, data: data, deadline: deadline, salt: salt })
            )
        );
    }

    function retry(uint64 sourceChainId, MessageType messageType, bytes calldata body) external restricted {
        _requireNotPaused();
        bytes32 messageHash = digestMessage(sourceChainId, messageType, body);
        if (messageStatus[messageHash] != MessageStatus.Failed) revert NotFailed();
        messageStatus[messageHash] = MessageStatus.Executed;
        emit MessageRetried(sourceChainId, messageType, messageHash);
        _execute(sourceChainId, messageType, body);
    }

    // ========================================= ADAPTER ========================================

    function receiveMessage(uint64 chainId, bytes calldata payload) external restricted {
        (MessageType messageType, bytes memory body) = abi.decode(payload, (MessageType, bytes));
        _handleMessage(chainId, messageType, body);
    }

    function _sendDepositMessage(
        address asset,
        uint256 amount,
        uint64 toChainId,
        address to,
        uint64 messageGas
    )
        internal
        returns (bytes32 messageHash)
    {
        _requireNotPaused();
        address adapter = messagingAdapter;
        if (adapter == address(0)) revert UnknownAdapter();
        bytes32 toAccountId = TransitTokenLib.formatAccountId(toChainId, to);
        messageHash = _sendMessage(
            IMessagingAdapter(adapter).HUB_CHAIN_ID(),
            messageGas,
            MessageType.Deposit,
            abi.encode(
                DepositMessage({
                    asset: asset, amount: amount, toAccountId: toAccountId, salt: bytes32(++outboundNonce)
                })
            )
        );
        emit Deposit(asset, msg.sender, toAccountId, amount);
    }

    function _sendMessage(
        uint64 chainId,
        uint64 messageGas,
        MessageType messageType,
        bytes memory body
    )
        internal
        returns (bytes32 messageHash)
    {
        messageHash = digestMessage(uint64(block.chainid), messageType, body);
        if (chainId == block.chainid) {
            if (msg.value != 0) revert NoFee();
            _handleMessage(chainId, messageType, body);
        } else {
            address adapter = messagingAdapter;
            if (adapter == address(0)) revert UnknownAdapter();
            IMessagingAdapter(adapter).send{ value: msg.value }(chainId, messageGas, abi.encode(messageType, body));
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
        return IMessagingAdapter(messagingAdapter).quote(chainId, messageGas, abi.encode(messageType, body));
    }

    function _handleMessage(uint64 chainId, MessageType messageType, bytes memory body) internal {
        _requireNotPaused();
        bytes32 messageHash = digestMessage(chainId, messageType, body);
        // A revert here leaves the delivery failed in the bridge's queue forever; it is never retried successfully.
        if (messageStatus[messageHash] != MessageStatus.None) revert MessageReplay();
        messageStatus[messageHash] = MessageStatus.Executed;
        _execute(chainId, messageType, body);
    }

    function _executeCall(
        address target,
        bytes memory data,
        uint256 value,
        bytes32 accountId
    )
        internal
        returns (bool ok, bytes memory result)
    {
        if (!routable[target][bytes4(data)]) return (false, abi.encodeWithSelector(NotRoutable.selector));
        (ok, result) = target.call{ value: value }(abi.encodePacked(data, accountId));
    }

    function _execute(uint64 sourceChainId, MessageType messageType, bytes memory body) internal {
        bool ok;
        bytes memory result;
        uint256 gasBefore;
        if (messageType == MessageType.Deposit) {
            if (hubWarehouseConductor == address(0)) revert NoHandler();
            DepositMessage memory message = abi.decode(body, (DepositMessage));
            gasBefore = gasleft();
            (ok, result) = hubWarehouseConductor.call(
                abi.encodeCall(
                    HubWarehouseConductor.receiveDeposit,
                    (sourceChainId, message.asset, message.amount, message.toAccountId)
                )
            );
        } else if (messageType == MessageType.Withdrawal) {
            if (SPOKE_WAREHOUSE == address(0)) revert NoHandler();
            WithdrawalMessage memory message = abi.decode(body, (WithdrawalMessage));
            gasBefore = gasleft();
            (ok, result) = SPOKE_WAREHOUSE.call(
                abi.encodeCall(SpokeWarehouse.receiveWithdrawal, (message.asset, message.amount, message.to))
            );
        } else {
            GenericMessage memory message = abi.decode(body, (GenericMessage));
            if (block.timestamp > message.deadline) {
                if (sourceChainId == block.chainid) revert Expired();
                bytes32 expiredHash = digestMessage(sourceChainId, messageType, body);
                messageStatus[expiredHash] = MessageStatus.Expired;
                emit MessageExpired(sourceChainId, messageType, expiredHash);
                return;
            }
            gasBefore = gasleft();
            (ok, result) = _executeCall(
                message.target, message.data, 0, TransitTokenLib.formatAccountId(sourceChainId, message.sender)
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
        messageStatus[messageHash] = MessageStatus.Failed;
        emit MessageFailed(sourceChainId, messageType, messageHash, body);
    }

}
