// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.37;

import { AccessManaged } from "@openzeppelin/contracts/access/manager/AccessManaged.sol";
import { Pausable } from "@openzeppelin/contracts/utils/Pausable.sol";
import { ERC20 } from "solady/tokens/ERC20.sol";
import { ReentrancyGuard } from "solady/utils/ReentrancyGuard.sol";
import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";
import { IMessagingAdapter } from "./messaging/IMessagingAdapter.sol";

contract Warehouse is AccessManaged, ReentrancyGuard, Pausable {

    struct BridgeData {
        uint64 chainId;
        address destinationChainReceiver;
        ERC20 bridgeFeeToken;
        uint64 messageGas;
        bytes data;
    }

    enum MessageType {
        Deposit,
        Withdrawal
    }

    struct TransferMessage {
        address asset;
        uint256 nonce;
        uint256 amount;
        address to;
    }

    address public immutable vault;
    uint256 public outboundNonce;

    IMessagingAdapter public messagingAdapter;

    mapping(uint64 sourceChainId => mapping(uint256 nonce => bool)) public messageConsumed;

    event MessagingAdapterUpdated(address indexed adapter);
    event Deposit(address indexed asset, address indexed from, address indexed to, uint256 amount);
    event MessageSent(bytes32 messageId, uint256 shareAmount, address to);
    event MessageReceived(bytes32 messageId, uint256 shareAmount, address to);

    error VaultUnset();
    error ZeroAssets();
    error MessageReplay();
    error UnknownAdapter();

    constructor(address _authority, address _vault) AccessManaged(_authority) {
        if (_vault == address(0)) revert VaultUnset();
        vault = _vault;
    }

    // ========================================= ADMIN =========================================

    function setMessagingAdapter(IMessagingAdapter adapter) external restricted {
        messagingAdapter = adapter;
        emit MessagingAdapterUpdated(address(adapter));
    }

    function pause() external restricted {
        _pause();
    }

    function unpause() external restricted {
        _unpause();
    }

    // ========================================= USER =========================================

    /// TODO: Decide whether admins need a per-asset deny-list now that any ERC20 is accepted.
    /// TODO: Only data.chainId and data.messageGas are read; destinationChainReceiver (`to` is used instead),
    /// bridgeFeeToken and data are ignored. Slim BridgeData or pass messageGas directly?
    function deposit(
        ERC20 asset,
        uint256 amount,
        address to,
        BridgeData calldata data
    )
        external
        payable
        nonReentrant
        returns (uint256 shares)
    {
        _requireNotPaused();
        if (amount == 0) revert ZeroAssets();

        shares = amount;
        SafeTransferLib.safeTransferFrom(address(asset), msg.sender, vault, amount);

        bytes memory payload = abi.encode(
            MessageType.Deposit,
            abi.encode(
                TransferMessage({
                    asset: address(asset),
                    nonce: ++outboundNonce,
                    amount: shares,
                    to: to
                })
            )
        );

        IMessagingAdapter adapter = messagingAdapter;
        if (address(adapter) == address(0)) revert UnknownAdapter();
        bytes32 messageId = adapter.send{ value: msg.value }(data.chainId, data.messageGas, payload);

        emit MessageSent(messageId, shares, to);

        emit Deposit(address(asset), msg.sender, to, amount);
    }

    function quoteBridge(BridgeData calldata data, bytes calldata payload) external view returns (uint256 fee) {
        IMessagingAdapter adapter = messagingAdapter;
        if (address(adapter) == address(0)) revert UnknownAdapter();
        return adapter.quote(data.chainId, data.messageGas, payload);
    }

    // ========================================= ADAPTER ========================================

    function receiveMessage(uint64 chainId, bytes calldata payload) external restricted nonReentrant {
        (MessageType messageType, bytes memory body) = abi.decode(payload, (MessageType, bytes));

        if (messageType == MessageType.Withdrawal) {
            TransferMessage[] memory messages = abi.decode(body, (TransferMessage[]));
            for (uint256 i; i < messages.length; i++) {
                _receiveTransfer(chainId, messages[i]);
            }
        } else {
            assert(false);
        }
    }

    function _receiveTransfer(uint64 sourceChainId, TransferMessage memory message) internal {
        // A revert here leaves the delivery failed in the bridge's queue forever; it is never retried successfully.
        if (messageConsumed[sourceChainId][message.nonce]) revert MessageReplay();
        messageConsumed[sourceChainId][message.nonce] = true;

        _requireNotPaused();
        SafeTransferLib.safeTransferFrom(message.asset, vault, message.to, message.amount);

        emit MessageReceived(bytes32(message.nonce), message.amount, message.to);
    }

}
