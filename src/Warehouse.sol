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
    function deposit(
        ERC20 asset,
        uint256 amount,
        address to,
        uint64 messageGas
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
            _hubChainId(),
            messageGas,
            MessageType.Deposit,
            abi.encode(TransferMessage({ asset: address(asset), nonce: ++outboundNonce, amount: shares, to: to }))
        );

        emit MessageSent(messageId, shares, to);

        emit Deposit(address(asset), msg.sender, to, amount);
    }

    function quoteBridge(uint64 messageGas, bytes calldata payload) external view returns (uint256 fee) {
        return messagingAdapter.quote(_hubChainId(), messageGas, payload);
    }

    function _hubChainId() internal view returns (uint64) {
        IMessagingAdapter adapter = messagingAdapter;
        if (address(adapter) == address(0)) revert UnknownAdapter();
        return adapter.hubChainId();
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
