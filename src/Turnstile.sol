// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.37;

import { AccessManaged } from "@openzeppelin/contracts/access/manager/AccessManaged.sol";
import { Pausable } from "@openzeppelin/contracts/utils/Pausable.sol";
import { ECDSA } from "solady/utils/ECDSA.sol";
import { EIP712 } from "solady/utils/EIP712.sol";
import { ReentrancyGuard } from "solady/utils/ReentrancyGuard.sol";
import { Depot } from "./Depot.sol";
import { ITurnstile } from "./ITurnstile.sol";
import { Warehouse } from "./Warehouse.sol";
import { TransitTokenLib } from "./helpers/TransitTokenLib.sol";
import { IMessagingAdapter } from "./messaging/IMessagingAdapter.sol";

contract Turnstile is AccessManaged, Pausable, ReentrancyGuard, EIP712, ITurnstile {

    bytes32 public constant FACILITATED_CALL_TYPEHASH = keccak256(
        "FacilitatedCall(address sender,address target,bytes data,bytes32 feeAssetId,uint256 fee,uint256 nonce,uint256 deadline)"
    );

    address public immutable DEPOT;
    address public immutable WAREHOUSE;

    IMessagingAdapter public messagingAdapter;
    uint256 public outboundNonce;

    mapping(bytes32 messageHash => bool) public messageConsumed;
    mapping(address target => mapping(bytes4 selector => bool)) public routable;
    mapping(bytes32 messageHash => bool) public failed;

    constructor(address _authority, address _depot, address _warehouse) AccessManaged(_authority) {
        DEPOT = _depot;
        WAREHOUSE = _warehouse;
    }

    function _domainNameAndVersion() internal pure override returns (string memory, string memory) {
        return ("Turnstile", "1");
    }

    // ========================================= ADMIN =========================================

    function setMessagingAdapter(IMessagingAdapter adapter) external restricted {
        messagingAdapter = adapter;
        emit MessagingAdapterUpdated(address(adapter));
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

    function sendGenericMessage(address target, bytes calldata data, uint64 messageGas) external payable nonReentrant {
        _requireNotPaused();
        IMessagingAdapter adapter = messagingAdapter;
        if (address(adapter) == address(0)) revert UnknownAdapter();
        _sendMessage(
            adapter.HUB_CHAIN_ID(),
            messageGas,
            MessageType.Generic,
            abi.encode(GenericMessage({ nonce: ++outboundNonce, sender: msg.sender, target: target, data: data }))
        );
    }

    function facilitate(
        FacilitatedCall[] calldata calls,
        bytes[] calldata signatures,
        uint256[] calldata values
    )
        external
        payable
        restricted
        nonReentrant
    {
        _requireNotPaused();
        if (DEPOT == address(0)) revert NoHandler();
        if (calls.length != signatures.length || calls.length != values.length) revert LengthMismatch();
        bytes32 facilitatorAccountId = TransitTokenLib.formatAccountId(uint64(block.chainid), msg.sender);
        for (uint256 i; i < calls.length; i++) {
            FacilitatedCall calldata facilitatedCall = calls[i];
            if (block.timestamp > facilitatedCall.deadline) revert Expired();
            bytes32 digest = hashFacilitatedCall(facilitatedCall);
            if (ECDSA.recoverCalldata(digest, signatures[i]) != facilitatedCall.sender) revert BadSignature();
            _consume(digest);
            if (!routable[facilitatedCall.target][bytes4(facilitatedCall.data)]) revert NotRoutable();
            bytes32 senderAccountId = TransitTokenLib.formatAccountId(uint64(block.chainid), facilitatedCall.sender);
            if (facilitatedCall.fee != 0) {
                Depot(DEPOT).transferFrom(
                    senderAccountId, facilitatorAccountId, facilitatedCall.feeAssetId, facilitatedCall.fee
                );
            }
            (bool ok, bytes memory result) = facilitatedCall.target.call{ value: values[i] }(
                abi.encodePacked(facilitatedCall.data, TransitTokenLib.formatFacilitatedAccountId(senderAccountId))
            );
            if (!ok) {
                assembly {
                    revert(add(result, 0x20), mload(result))
                }
            }
        }
    }

    function hashFacilitatedCall(FacilitatedCall calldata facilitatedCall) public view returns (bytes32) {
        return _hashTypedData(
            keccak256(
                abi.encode(
                    FACILITATED_CALL_TYPEHASH,
                    facilitatedCall.sender,
                    facilitatedCall.target,
                    keccak256(facilitatedCall.data),
                    facilitatedCall.feeAssetId,
                    facilitatedCall.fee,
                    facilitatedCall.nonce,
                    facilitatedCall.deadline
                )
            )
        );
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
        address target,
        bytes calldata data,
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
            abi.encode(GenericMessage({ nonce: outboundNonce + 1, sender: msg.sender, target: target, data: data }))
        );
    }

    function retry(uint64 sourceChainId, MessageType messageType, bytes calldata body) external restricted nonReentrant {
        _requireNotPaused();
        bytes32 messageHash = keccak256(abi.encode(sourceChainId, messageType, body));
        if (!failed[messageHash]) revert NotFailed();
        delete failed[messageHash];
        emit MessageRetried(sourceChainId, messageType, messageHash);
        _execute(sourceChainId, messageType, body);
    }

    // ========================================= ADAPTER ========================================

    function receiveMessage(uint64 chainId, bytes calldata payload) external restricted nonReentrant {
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
        _consume(keccak256(abi.encode(chainId, messageType, body)));
        _execute(chainId, messageType, body);
    }

    function _consume(bytes32 messageHash) internal {
        // A revert here leaves the delivery failed in the bridge's queue forever; it is never retried successfully.
        if (messageConsumed[messageHash]) revert MessageReplay();
        messageConsumed[messageHash] = true;
    }

    function _execute(uint64 sourceChainId, MessageType messageType, bytes memory body) internal {
        bool ok;
        bytes memory result;
        uint256 gasBefore;
        if (messageType == MessageType.Deposit) {
            if (DEPOT == address(0)) revert NoHandler();
            DepositMessage memory message = abi.decode(body, (DepositMessage));
            gasBefore = gasleft();
            (ok, result) = DEPOT.call(abi.encodeCall(Depot.receiveDeposit, (sourceChainId, message.asset, message.amount, message.toAccountId)));
        } else if (messageType == MessageType.Withdrawal) {
            if (WAREHOUSE == address(0)) revert NoHandler();
            WithdrawalMessage memory message = abi.decode(body, (WithdrawalMessage));
            gasBefore = gasleft();
            (ok, result) = WAREHOUSE.call(abi.encodeCall(Warehouse.receiveWithdrawal, (message.asset, message.amount, message.to)));
        } else {
            GenericMessage memory message = abi.decode(body, (GenericMessage));
            if (routable[message.target][bytes4(message.data)]) {
                gasBefore = gasleft();
                (ok, result) = message.target.call(
                    abi.encodePacked(message.data, TransitTokenLib.formatAccountId(sourceChainId, message.sender))
                );
            } else {
                result = abi.encodeWithSelector(NotRoutable.selector);
            }
        }
        if (ok) return;
        if (sourceChainId == block.chainid) {
            assembly {
                revert(add(result, 0x20), mload(result))
            }
        }
        if (gasleft() <= gasBefore / 63) revert OutOfGas();
        bytes32 messageHash = keccak256(abi.encode(sourceChainId, messageType, body));
        failed[messageHash] = true;
        emit MessageFailed(sourceChainId, messageType, messageHash, body);
    }

}
