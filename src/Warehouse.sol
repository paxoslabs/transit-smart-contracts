// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.37;

import { ERC20 } from "solady/tokens/ERC20.sol";
import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";
import { IMessagingAdapter } from "./messaging/IMessagingAdapter.sol";
import { MessagingEndpoint } from "./messaging/MessagingEndpoint.sol";

contract Warehouse is MessagingEndpoint {

    address public immutable vault;

    event Deposit(address indexed asset, address indexed from, address indexed to, uint256 amount);

    error VaultUnset();
    error ZeroAssets();

    constructor(address _authority, address _vault) MessagingEndpoint(_authority) {
        if (_vault == address(0)) revert VaultUnset();
        vault = _vault;
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

        bytes32 messageId = _sendMessage(
            data.chainId,
            data.messageGas,
            MessageType.Deposit,
            abi.encode(TransferMessage({ asset: address(asset), nonce: ++outboundNonce, amount: shares, to: to }))
        );

        emit MessageSent(messageId, shares, to);

        emit Deposit(address(asset), msg.sender, to, amount);
    }

    function quoteBridge(BridgeData calldata data, bytes calldata payload) external view returns (uint256 fee) {
        IMessagingAdapter adapter = messagingAdapter;
        if (address(adapter) == address(0)) revert UnknownAdapter();
        return adapter.quote(data.chainId, data.messageGas, payload);
    }

    // ========================================= ADAPTER ========================================

    function _handleMessage(uint64 chainId, MessageType messageType, bytes memory body) internal override {
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
        _consume(sourceChainId, message.nonce);

        _requireNotPaused();
        SafeTransferLib.safeTransferFrom(message.asset, vault, message.to, message.amount);

        emit MessageReceived(bytes32(message.nonce), message.amount, message.to);
    }

}
