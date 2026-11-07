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

    bytes32 public constant DEPOSIT_ACTION_TYPEHASH = keccak256(
        "DepositAction(address asset,uint256 amount,uint64 toChainId,address to,uint256 deadline,bytes32 salt,Permit permit)Permit(uint256 deadline,uint8 v,bytes32 r,bytes32 s)"
    );
    bytes32 public constant PERMIT_TYPEHASH = keccak256("Permit(uint256 deadline,uint8 v,bytes32 r,bytes32 s)");
    bytes32 public constant WITHDRAW_ACTION_TYPEHASH = keccak256(
        "WithdrawAction(uint64 ownerChainId,address owner,address to,bytes32 assetId,uint256 amount,uint256 deadline,bool partiallyFillable,bytes32 salt)"
    );
    bytes32 public constant GENERIC_ACTION_TYPEHASH =
        keccak256("GenericAction(address target,bytes data,uint256 deadline,bytes32 salt)");

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

    function dispatch(
        ActionType[] calldata actionTypes,
        bytes[] calldata actionData,
        uint256[] calldata fares,
        uint64[] calldata messageGas
    )
        external
        payable
        returns (bytes32[] memory messageHashes)
    {
        messageHashes = _dispatch(actionTypes, actionData, new bytes[](0), fares, messageGas, false);
    }

    /// TODO: Decide how facilitate charges fees; a fee call can no longer be bundled with the facilitated call.
    /// TODO: Decide messageGas for facilitated actions. Currently an unsigned per-action value chosen by the
    /// facilitator.
    function facilitate(
        ActionType[] calldata actionTypes,
        bytes[] calldata actionData,
        bytes[] calldata signatures,
        uint256[] calldata fares,
        uint64[] calldata messageGas
    )
        external
        payable
        restricted
    {
        _dispatch(actionTypes, actionData, signatures, fares, messageGas, true);
    }

    function hashDepositAction(DepositAction memory action) public view returns (bytes32) {
        return _hashTypedData(
            keccak256(
                abi.encode(
                    DEPOSIT_ACTION_TYPEHASH,
                    action.asset,
                    action.amount,
                    action.toChainId,
                    action.to,
                    action.deadline,
                    action.salt,
                    keccak256(
                        abi.encode(
                            PERMIT_TYPEHASH, action.permit.deadline, action.permit.v, action.permit.r, action.permit.s
                        )
                    )
                )
            )
        );
    }

    function hashWithdrawAction(WithdrawAction memory action) public view returns (bytes32) {
        return _hashTypedData(
            keccak256(
                abi.encode(
                    WITHDRAW_ACTION_TYPEHASH,
                    action.ownerChainId,
                    action.owner,
                    action.to,
                    action.assetId,
                    action.amount,
                    action.deadline,
                    action.partiallyFillable,
                    action.salt
                )
            )
        );
    }

    function hashGenericAction(GenericAction memory action) public view returns (bytes32) {
        return _hashTypedData(
            keccak256(
                abi.encode(GENERIC_ACTION_TYPEHASH, action.target, keccak256(action.data), action.deadline, action.salt)
            )
        );
    }

    function digestMessage(uint64 chainId, MessageType messageType, bytes memory body) public pure returns (bytes32) {
        return keccak256(abi.encode(chainId, messageType, body));
    }

    function quote(
        ActionType[] calldata actionTypes,
        bytes[] calldata actionData,
        uint64[] calldata messageGas
    )
        external
        view
        returns (uint256[] memory fares)
    {
        if (actionTypes.length != actionData.length || actionData.length != messageGas.length) {
            revert LengthMismatch();
        }
        fares = new uint256[](actionData.length);
        for (uint256 i; i < actionData.length; i++) {
            if (actionTypes[i] == ActionType.Deposit) {
                DepositAction memory action = abi.decode(actionData[i], (DepositAction));
                address adapter = messagingAdapter;
                if (adapter == address(0)) revert UnknownAdapter();
                fares[i] = _quote(
                    IMessagingAdapter(adapter).HUB_CHAIN_ID(),
                    messageGas[i],
                    MessageType.Deposit,
                    abi.encode(
                        DepositMessage({
                            asset: action.asset,
                            amount: action.amount,
                            toAccountId: TransitTokenLib.formatAccountId(action.toChainId, action.to),
                            salt: bytes32(outboundNonce + 1)
                        })
                    )
                );
            } else if (actionTypes[i] == ActionType.Withdraw) {
                WithdrawAction memory action = abi.decode(actionData[i], (WithdrawAction));
                (uint64 assetChainId, address asset) = TransitTokenLib.parseAssetId(action.assetId);
                fares[i] = _quote(
                    assetChainId,
                    messageGas[i],
                    MessageType.Withdrawal,
                    abi.encode(
                        WithdrawalMessage({
                            asset: asset, amount: action.amount, to: action.to, salt: bytes32(outboundNonce + 1)
                        })
                    )
                );
            } else {
                GenericAction memory action = abi.decode(actionData[i], (GenericAction));
                address adapter = messagingAdapter;
                if (adapter == address(0)) revert UnknownAdapter();
                fares[i] = _quote(
                    IMessagingAdapter(adapter).HUB_CHAIN_ID(),
                    messageGas[i],
                    MessageType.Generic,
                    abi.encode(
                        GenericMessage({
                            sender: msg.sender,
                            target: action.target,
                            data: action.data,
                            deadline: action.deadline,
                            salt: action.salt
                        })
                    )
                );
            }
        }
    }

    /// TODO: Decide whether retry needs to be admin-only. receiveMessage also re-executes Failed messages on bridge
    /// redelivery.
    function retry(uint64 sourceChainId, MessageType messageType, bytes calldata body) external restricted {
        bytes32 messageHash = digestMessage(sourceChainId, messageType, body);
        if (messageStatus[messageHash] != MessageStatus.Failed) revert NotFailed();
        emit MessageRetried(sourceChainId, messageType, messageHash);
        _handleMessage(sourceChainId, messageType, body, false);
    }

    // ========================================= ADAPTER ========================================

    function receiveMessage(uint64 chainId, bytes calldata payload) external restricted {
        (MessageType messageType, bytes memory body) = abi.decode(payload, (MessageType, bytes));
        _handleMessage(chainId, messageType, body, false);
    }

    function _dispatch(
        ActionType[] calldata actionTypes,
        bytes[] calldata actionData,
        bytes[] memory signatures,
        uint256[] calldata fares,
        uint64[] calldata messageGas,
        bool facilitated
    )
        internal
        returns (bytes32[] memory messageHashes)
    {
        _requireNotPaused();
        if (
            actionTypes.length != actionData.length || actionData.length != fares.length
                || actionData.length != messageGas.length || (facilitated && actionData.length != signatures.length)
        ) revert LengthMismatch();
        messageHashes = new bytes32[](actionData.length);
        uint256 totalFare;
        for (uint256 i; i < actionData.length; i++) {
            totalFare += fares[i];
            bytes memory signature = facilitated ? signatures[i] : bytes("");
            if (actionTypes[i] == ActionType.Deposit) {
                messageHashes[i] = _dispatchDeposit(
                    abi.decode(actionData[i], (DepositAction)), signature, fares[i], messageGas[i], facilitated
                );
            } else if (actionTypes[i] == ActionType.Withdraw) {
                messageHashes[i] = _dispatchWithdraw(
                    abi.decode(actionData[i], (WithdrawAction)), signature, fares[i], messageGas[i], facilitated
                );
            } else {
                messageHashes[i] = _dispatchGeneric(
                    abi.decode(actionData[i], (GenericAction)), signature, fares[i], messageGas[i], facilitated
                );
            }
        }
        if (totalFare != msg.value) revert FareMismatch();
    }

    function _dispatchDeposit(
        DepositAction memory action,
        bytes memory signature,
        uint256 fare,
        uint64 messageGas,
        bool facilitated
    )
        internal
        returns (bytes32 messageHash)
    {
        address from = msg.sender;
        if (facilitated) {
            from = ECDSA.recover(hashDepositAction(action), signature);
            _consumeAction(MessageType.Deposit, abi.encode(from, action));
        }
        if (block.timestamp > action.deadline) revert Expired();
        if (action.permit.deadline != 0) {
            try SpokeWarehouse(SPOKE_WAREHOUSE).permit(from, action.asset, action.amount, action.permit) { }
                catch {
                // Ignored: a front-run permit fails here but still grants the allowance. No allowance check,
                // since custody may pull via token allowance or Permit2; it reverts if neither covers amount.
            }
        }
        SpokeWarehouse(SPOKE_WAREHOUSE).custody(from, action.asset, action.amount);
        address adapter = messagingAdapter;
        if (adapter == address(0)) revert UnknownAdapter();
        bytes32 toAccountId = TransitTokenLib.formatAccountId(action.toChainId, action.to);
        messageHash = _sendMessage(
            IMessagingAdapter(adapter).HUB_CHAIN_ID(),
            messageGas,
            MessageType.Deposit,
            abi.encode(
                DepositMessage({
                    asset: action.asset, amount: action.amount, toAccountId: toAccountId, salt: bytes32(++outboundNonce)
                })
            ),
            fare,
            false
        );
        emit Deposit(action.asset, from, toAccountId, action.amount);
    }

    /// TODO: Decide what happens to fare when an expired or empty withdrawal sends no message. Currently it stays in
    /// Turnstile.
    function _dispatchWithdraw(
        WithdrawAction memory action,
        bytes memory signature,
        uint256 fare,
        uint64 messageGas,
        bool facilitated
    )
        internal
        returns (bytes32 messageHash)
    {
        bytes32 accountId;
        {
            address owner = msg.sender;
            if (facilitated) {
                owner = ECDSA.recover(hashWithdrawAction(action), signature);
                _consumeAction(MessageType.Withdrawal, abi.encode(owner, action));
            }
            accountId = TransitTokenLib.formatAccountId(uint64(block.chainid), owner);
            if (facilitated) accountId = TransitTokenLib.formatFacilitatedAccountId(accountId);
        }
        uint256 amount;
        {
            address handler = hubWarehouseConductor;
            if (handler == address(0)) revert NoHandler();
            (bool ok, bytes memory result) = handler.call(
                abi.encodePacked(abi.encodeCall(HubWarehouseConductor.executeWithdrawal, (action)), accountId)
            );
            if (!ok) {
                assembly {
                    revert(add(result, 0x20), mload(result))
                }
            }
            amount = abi.decode(result, (uint256));
        }
        if (amount == 0) return bytes32(0);
        (uint64 assetChainId, address asset) = TransitTokenLib.parseAssetId(action.assetId);
        messageHash = _sendMessage(
            assetChainId,
            messageGas,
            MessageType.Withdrawal,
            abi.encode(
                WithdrawalMessage({ asset: asset, amount: amount, to: action.to, salt: bytes32(++outboundNonce) })
            ),
            fare,
            false
        );
    }

    function _dispatchGeneric(
        GenericAction memory action,
        bytes memory signature,
        uint256 fare,
        uint64 messageGas,
        bool facilitated
    )
        internal
        returns (bytes32 messageHash)
    {
        address sender = msg.sender;
        if (facilitated) sender = ECDSA.recover(hashGenericAction(action), signature);
        address adapter = messagingAdapter;
        if (adapter == address(0)) revert UnknownAdapter();
        messageHash = _sendMessage(
            IMessagingAdapter(adapter).HUB_CHAIN_ID(),
            messageGas,
            MessageType.Generic,
            abi.encode(
                GenericMessage({
                    sender: sender,
                    target: action.target,
                    data: action.data,
                    deadline: action.deadline,
                    salt: action.salt
                })
            ),
            fare,
            facilitated
        );
    }

    /// TODO: Decide the deposit/withdraw action replay key. Currently digestMessage over (signer, action) under the
    /// matching MessageType, as generic actions are keyed by their GenericMessage.
    function _consumeAction(MessageType messageType, bytes memory body) internal {
        bytes32 actionHash = digestMessage(uint64(block.chainid), messageType, body);
        if (messageStatus[actionHash] != MessageStatus.None) revert MessageReplay();
        messageStatus[actionHash] = MessageStatus.Executed;
    }

    function _sendMessage(
        uint64 chainId,
        uint64 messageGas,
        MessageType messageType,
        bytes memory body,
        uint256 fare,
        bool facilitated
    )
        internal
        returns (bytes32 messageHash)
    {
        messageHash = digestMessage(uint64(block.chainid), messageType, body);
        if (chainId == block.chainid) {
            if (fare != 0) revert NoFare();
            _handleMessage(chainId, messageType, body, facilitated);
        } else {
            address adapter = messagingAdapter;
            if (adapter == address(0)) revert UnknownAdapter();
            IMessagingAdapter(adapter).send{ value: fare }(chainId, messageGas, abi.encode(messageType, body));
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

    function _handleMessage(uint64 chainId, MessageType messageType, bytes memory body, bool facilitated) internal {
        _requireNotPaused();
        bytes32 messageHash = digestMessage(chainId, messageType, body);
        // A revert here leaves the delivery failed in the bridge's queue forever; it is never retried successfully.
        MessageStatus status = messageStatus[messageHash];
        if (status != MessageStatus.None && status != MessageStatus.Failed) revert MessageReplay();
        messageStatus[messageHash] = MessageStatus.Executed;
        bool ok;
        bytes memory result;
        uint256 gasBefore;
        if (messageType == MessageType.Deposit) {
            if (hubWarehouseConductor == address(0)) revert NoHandler();
            DepositMessage memory message = abi.decode(body, (DepositMessage));
            gasBefore = gasleft();
            (ok, result) = hubWarehouseConductor.call(
                abi.encodeCall(
                    HubWarehouseConductor.receiveDeposit, (chainId, message.asset, message.amount, message.toAccountId)
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
                if (chainId == block.chainid) revert Expired();
                messageStatus[messageHash] = MessageStatus.Expired;
                emit MessageExpired(chainId, messageType, messageHash);
                return;
            }
            gasBefore = gasleft();
            bytes32 accountId = TransitTokenLib.formatAccountId(chainId, message.sender);
            if (facilitated) accountId = TransitTokenLib.formatFacilitatedAccountId(accountId);
            if (routable[message.target][bytes4(message.data)]) {
                (ok, result) = message.target.call(abi.encodePacked(message.data, accountId));
            } else {
                result = abi.encodeWithSelector(NotRoutable.selector);
            }
        }
        if (ok) return;
        if (chainId == block.chainid) {
            assembly {
                revert(add(result, 0x20), mload(result))
            }
        }
        if (gasleft() <= gasBefore / 63) revert OutOfGas();
        messageStatus[messageHash] = MessageStatus.Failed;
        emit MessageFailed(chainId, messageType, messageHash, body);
    }

}
