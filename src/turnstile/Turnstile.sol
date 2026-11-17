// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.37;

import { AccessManaged } from "@openzeppelin/contracts/access/manager/AccessManaged.sol";
import { Pausable } from "@openzeppelin/contracts/utils/Pausable.sol";
import { ECDSA } from "solady/utils/ECDSA.sol";
import { EIP712 } from "solady/utils/EIP712.sol";
import { ITurnstile } from "./ITurnstile.sol";
import { Typehashes } from "../helpers/Typehashes.sol";
import { HubWarehouseConductor } from "../conductor/HubWarehouseConductor.sol";
import { SpokeWarehouse } from "../SpokeWarehouse.sol";
import { TransitTokenLib } from "../helpers/TransitTokenLib.sol";
import { IMessagingAdapter } from "../messaging/IMessagingAdapter.sol";

contract Turnstile is AccessManaged, Pausable, EIP712, ITurnstile {

    /// @inheritdoc ITurnstile
    address public immutable SPOKE_WAREHOUSE;

    /// @inheritdoc ITurnstile
    address public messagingAdapter;
    /// @inheritdoc ITurnstile
    address public hubWarehouseConductor;

    /// @inheritdoc ITurnstile
    mapping(bytes32 messageHash => MessageStatus) public messageStatus;
    /// @inheritdoc ITurnstile
    mapping(address target => mapping(bytes4 selector => bool)) public genericMessageWhitelist;

    constructor(address _authority, address _spokeWarehouse) AccessManaged(_authority) {
        SPOKE_WAREHOUSE = _spokeWarehouse;
        /// NOTE: messagingAdapter is not set here because MessagingAdapter takes this Turnstile as its immutable
        /// ENDPOINT, making constructor wiring circular. We could instead check !=0 on ever call as was done before.
        /// But this saves the check for only on set. And the window between deploy and setting still reverts, just with
        /// a less convinient error. This is an efficiency gain for no less security but slightly less verbosity that
        /// should never occur anyways with a deployment script
    }

    function _domainNameAndVersion() internal pure override returns (string memory, string memory) {
        return ("Transit Turnstile", "1");
    }

    // ========================================= ADMIN =========================================

    /// @inheritdoc ITurnstile
    function setMessagingAdapter(address adapter) external restricted {
        if (adapter.code.length == 0) revert NoCode();
        messagingAdapter = adapter;
        emit MessagingAdapterUpdated(adapter);
    }

    /// @inheritdoc ITurnstile
    function setHubWarehouseConductor(address _hubWarehouseConductor) external restricted {
        if (_hubWarehouseConductor.code.length == 0) revert NoCode();
        hubWarehouseConductor = _hubWarehouseConductor;
        emit HubWarehouseConductorUpdated(_hubWarehouseConductor);
    }

    /// @inheritdoc ITurnstile
    function setRoutable(address target, bytes4[] calldata selectors, bool allowed) external restricted {
        for (uint256 i; i < selectors.length; i++) {
            genericMessageWhitelist[target][selectors[i]] = allowed;
        }
    }

    /// @inheritdoc ITurnstile
    function pause() external restricted {
        _pause();
    }

    /// @inheritdoc ITurnstile
    function unpause() external restricted {
        _unpause();
    }

    /// @inheritdoc ITurnstile
    function dispatch(Action[] calldata actions) external payable returns (bytes32[] memory messageHashes) {
        messageHashes = _dispatch(actions, new bytes[](0), false);
    }

    /// @dev TODO: Decide how facilitate charges fees; a fee call can no longer be bundled with the facilitated call.
    /// TODO: Decide messageGas for facilitated actions. Currently an unsigned per-action value chosen by the
    /// facilitator.
    /// @inheritdoc ITurnstile
    function facilitate(Action[] calldata actions, bytes[] calldata signatures) external payable restricted {
        _dispatch(actions, signatures, true);
    }

    /// @inheritdoc ITurnstile
    function hashDepositAction(DepositAction memory action) public view returns (bytes32) {
        return _hashTypedData(
            keccak256(
                abi.encode(
                    Typehashes.DEPOSIT_ACTION,
                    action.asset,
                    action.amount,
                    action.toChainId,
                    action.to,
                    action.deadline,
                    action.salt,
                    keccak256(
                        abi.encode(
                            Typehashes.PERMIT, action.permit.deadline, action.permit.v, action.permit.r, action.permit.s
                        )
                    )
                )
            )
        );
    }

    /// @inheritdoc ITurnstile
    function hashWithdrawalAction(WithdrawalAction memory action) public view returns (bytes32) {
        return _hashTypedData(
            keccak256(
                abi.encode(
                    Typehashes.WITHDRAWAL_ACTION,
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

    /// @inheritdoc ITurnstile
    function hashGenericAction(GenericAction memory action) public view returns (bytes32) {
        return _hashTypedData(
            keccak256(
                abi.encode(
                    Typehashes.GENERIC_ACTION, action.target, keccak256(action.data), action.deadline, action.salt
                )
            )
        );
    }

    /// @inheritdoc ITurnstile
    function digestMessage(uint64 chainId, ActionType actionType, bytes memory body) public pure returns (bytes32) {
        return keccak256(abi.encode(chainId, actionType, body));
    }

    /// @inheritdoc ITurnstile
    function quote(Action[] calldata actions) external view returns (uint256[] memory fares) {
        fares = new uint256[](actions.length);
        for (uint256 i; i < actions.length; i++) {
            if (actions[i].actionType == ActionType.Deposit) {
                DepositAction memory action = abi.decode(actions[i].data, (DepositAction));
                fares[i] = _quote(
                    IMessagingAdapter(messagingAdapter).HUB_CHAIN_ID(),
                    actions[i].messageGas,
                    ActionType.Deposit,
                    abi.encode(
                        DepositMessage({
                            asset: action.asset,
                            amount: action.amount,
                            fromAccountId: TransitTokenLib.formatAccountId(uint64(block.chainid), msg.sender, false),
                            toAccountId: TransitTokenLib.formatAccountId(action.toChainId, action.to, false),
                            salt: action.salt
                        })
                    )
                );
            } else if (actions[i].actionType == ActionType.Withdrawal) {
                WithdrawalAction memory action = abi.decode(actions[i].data, (WithdrawalAction));
                (uint64 assetChainId, address asset) = TransitTokenLib.parseAssetId(action.assetId);
                fares[i] = _quote(
                    assetChainId,
                    actions[i].messageGas,
                    ActionType.Withdrawal,
                    abi.encode(
                        WithdrawalMessage({
                            asset: asset, amount: action.amount, to: action.to, salt: hashWithdrawalAction(action)
                        })
                    )
                );
            } else {
                GenericAction memory action = abi.decode(actions[i].data, (GenericAction));
                fares[i] = _quote(
                    IMessagingAdapter(messagingAdapter).HUB_CHAIN_ID(),
                    actions[i].messageGas,
                    ActionType.Generic,
                    abi.encode(
                        GenericMessage({
                            sender: msg.sender,
                            facilitated: false,
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

    /// @inheritdoc ITurnstile
    function retry(uint64 sourceChainId, ActionType actionType, bytes calldata body) external restricted {
        bytes32 messageHash = digestMessage(sourceChainId, actionType, body);
        if (messageStatus[messageHash] != MessageStatus.Failed) revert NotFailed();
        delete messageStatus[messageHash];
        emit MessageRetried(sourceChainId, actionType, messageHash);
        _sendMessage(sourceChainId, uint64(block.chainid), 0, actionType, body, 0);
    }

    // ========================================= ADAPTER ========================================

    function receiveMessage(uint64 chainId, bytes calldata payload) external restricted {
        (ActionType actionType, bytes memory body) = abi.decode(payload, (ActionType, bytes));
        _sendMessage(chainId, uint64(block.chainid), 0, actionType, body, 0);
    }

    function _dispatch(
        Action[] calldata actions,
        bytes[] memory signatures,
        bool facilitated
    )
        internal
        returns (bytes32[] memory messageHashes)
    {
        _requireNotPaused();
        if (facilitated && actions.length != signatures.length) revert LengthMismatch();
        messageHashes = new bytes32[](actions.length);
        uint256 totalFare;
        for (uint256 i; i < actions.length; i++) {
            totalFare += actions[i].fare;
            messageHashes[i] = _dispatchAction(actions[i], facilitated ? signatures[i] : bytes(""), facilitated);
        }
        if (totalFare != msg.value) revert FareMismatch();
    }

    function _dispatchAction(
        Action calldata action,
        bytes memory signature,
        bool facilitated
    )
        internal
        returns (bytes32 messageHash)
    {
        ActionType actionType = action.actionType;
        uint64 chainId;
        bytes memory body;
        if (actionType == ActionType.Deposit) {
            (chainId, body) = _dispatchDeposit(action.data, signature, facilitated);
        } else if (actionType == ActionType.Withdrawal) {
            (chainId, body) = _dispatchWithdraw(action.data, signature, facilitated);
        } else {
            (chainId, body) = _dispatchGeneric(action.data, signature, facilitated);
        }
        /// TODO: Decide what happens to fare when an expired or empty withdrawal sends no message. Currently it stays
        /// in Turnstile.
        if (body.length != 0) {
            messageHash = _sendMessage(uint64(block.chainid), chainId, action.messageGas, actionType, body, action.fare);
        }
    }

    function _dispatchDeposit(
        bytes calldata actionData,
        bytes memory signature,
        bool facilitated
    )
        private
        returns (uint64 chainId, bytes memory body)
    {
        DepositAction memory action = abi.decode(actionData, (DepositAction));
        address from = facilitated ? ECDSA.recover(hashDepositAction(action), signature) : msg.sender;
        if (block.timestamp > action.deadline) revert Expired();
        if (action.permit.deadline != 0) {
            try SpokeWarehouse(SPOKE_WAREHOUSE).permit(from, action.asset, action.amount, action.permit) { }
                catch {
                // Ignored: a front-run permit fails here but still grants the allowance. No allowance check,
                // since custody may pull via token allowance or Permit2; it reverts if neither covers amount.
            }
        }
        SpokeWarehouse(SPOKE_WAREHOUSE).custody(from, action.asset, action.amount);
        bytes32 fromAccountId = TransitTokenLib.formatAccountId(uint64(block.chainid), from, false);
        bytes32 toAccountId = TransitTokenLib.formatAccountId(action.toChainId, action.to, false);
        chainId = IMessagingAdapter(messagingAdapter).HUB_CHAIN_ID();
        body = abi.encode(
            DepositMessage({
                asset: action.asset,
                amount: action.amount,
                fromAccountId: fromAccountId,
                toAccountId: toAccountId,
                salt: action.salt
            })
        );
        emit Deposit(action.asset, from, toAccountId, action.amount);
    }

    function _dispatchWithdraw(
        bytes calldata actionData,
        bytes memory signature,
        bool facilitated
    )
        private
        returns (uint64 chainId, bytes memory body)
    {
        WithdrawalAction memory action = abi.decode(actionData, (WithdrawalAction));
        bytes32 accountId;
        {
            address owner = facilitated ? ECDSA.recover(hashWithdrawalAction(action), signature) : msg.sender;
            accountId = TransitTokenLib.formatAccountId(uint64(block.chainid), owner, facilitated);
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
        if (amount == 0) return (0, "");
        address asset;
        (chainId, asset) = TransitTokenLib.parseAssetId(action.assetId);
        body = abi.encode(
            WithdrawalMessage({ asset: asset, amount: amount, to: action.to, salt: hashWithdrawalAction(action) })
        );
    }

    function _dispatchGeneric(
        bytes calldata actionData,
        bytes memory signature,
        bool facilitated
    )
        private
        returns (uint64 chainId, bytes memory body)
    {
        GenericAction memory action = abi.decode(actionData, (GenericAction));
        address sender = facilitated ? ECDSA.recover(hashGenericAction(action), signature) : msg.sender;
        chainId = IMessagingAdapter(messagingAdapter).HUB_CHAIN_ID();
        body = abi.encode(
            GenericMessage({
                sender: sender,
                facilitated: facilitated,
                target: action.target,
                data: action.data,
                deadline: action.deadline,
                salt: action.salt
            })
        );
    }

    function _sendMessage(
        uint64 sourceChainId,
        uint64 destinationChainId,
        uint64 messageGas,
        ActionType actionType,
        bytes memory body,
        uint256 fare
    )
        internal
        returns (bytes32 messageHash)
    {
        messageHash = digestMessage(sourceChainId, actionType, body);

        if (messageStatus[messageHash] != MessageStatus.None) revert MessageReplay();
        messageStatus[messageHash] = MessageStatus.Executed;

        if (destinationChainId == block.chainid) {
            // Same-chain messages bypass the MessagingAdapter and are executed by the Turnstile directly.
            if (fare != 0) revert NoFare();
            _executeMessage(sourceChainId, actionType, body);
        } else {
            // Cross-chain messages are encoded and forwarded to the MessagingAdapter.
            IMessagingAdapter(messagingAdapter).send{ value: fare }(
                destinationChainId, messageGas, abi.encode(actionType, body)
            );
        }
    }

    function _quote(
        uint64 chainId,
        uint64 messageGas,
        ActionType actionType,
        bytes memory body
    )
        internal
        view
        returns (uint256)
    {
        if (chainId == block.chainid) return 0;
        return IMessagingAdapter(messagingAdapter).quote(chainId, messageGas, abi.encode(actionType, body));
    }

    /// @notice Atempt to execute a message on the local chain.
    /// @param chainId Message's source chainId.
    /// @param actionType Message's ActionType.
    /// @param body Message's body.
    function _executeMessage(uint64 chainId, ActionType actionType, bytes memory body) internal {
        _requireNotPaused();

        bytes32 messageHash = digestMessage(chainId, actionType, body);

        address target;
        bytes memory data;
        bytes memory result;

        if (actionType == ActionType.Deposit) {
            DepositMessage memory message = abi.decode(body, (DepositMessage));
            target = hubWarehouseConductor;
            data = abi.encodeCall(
                HubWarehouseConductor.receiveDeposit,
                (chainId, message.asset, message.amount, message.fromAccountId, message.toAccountId)
            );
        } else if (actionType == ActionType.Withdrawal) {
            WithdrawalMessage memory message = abi.decode(body, (WithdrawalMessage));
            target = SPOKE_WAREHOUSE;
            data = abi.encodeCall(SpokeWarehouse.receiveWithdrawal, (message.asset, message.amount, message.to));
        } else {
            GenericMessage memory message = abi.decode(body, (GenericMessage));

            if (block.timestamp > message.deadline) {
                result = abi.encodeWithSelector(Expired.selector);
            } else if (!genericMessageWhitelist[message.target][bytes4(message.data)]) {
                result = abi.encodeWithSelector(NotWhitelisted.selector);
            } else {
                target = message.target;
                // Append accountId to calldata so that it may be used as meta-transaction sender.
                data = abi.encodePacked(
                    message.data, TransitTokenLib.formatAccountId(chainId, message.sender, message.facilitated)
                );
            }
        }

        uint256 gasBefore;

        // If result is set, it's an encoded pre-call error, so skip the call.
        if (result.length == 0) {
            if (target == address(0)) revert NoHandler();
            gasBefore = gasleft();
            bool ok;
            (ok, result) = target.call(data);
            if (ok) return;
        }

        // Same-chain reverts are atomic and should revert the entire action.
        if (chainId == block.chainid) {
            assembly {
                revert(add(result, 0x20), mload(result))
            }
        }

        // Cross-chain out-of-gas errors must revert the entire transaction to allow bridge-level retries.
        // The EIP-150 internal transaction gas limit of 63/64 is used a heuristic out-of-gas indicator, but
        // is subject to false positives, such as on assertion failure in solidity pre-0.8.
        if (gasleft() <= gasBefore / 63) revert OutOfGas();

        // Cross-chain internal errors are tracked internally to allow contract-level retries.
        messageStatus[messageHash] = MessageStatus.Failed;
        emit MessageFailed(chainId, actionType, messageHash, body);
    }

}
