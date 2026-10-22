// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.37;

import { ERC20 } from "solady/tokens/ERC20.sol";
import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";
import { IMessagingAdapter } from "./messaging/IMessagingAdapter.sol";
import { MessagingEndpoint } from "./messaging/MessagingEndpoint.sol";
import { Hub } from "./Hub.sol";
import { TransitTokenLib } from "./helpers/TransitTokenLib.sol";

contract Warehouse is MessagingEndpoint {

    address public immutable vault;

    mapping(address asset => bool) public assetWhitelisted;

    event Deposit(address indexed asset, address indexed from, bytes32 indexed toAccountId, uint256 amount);

    error VaultUnset();
    error ZeroAssets();
    error AssetNotWhitelisted();

    constructor(address _authority, address _vault) MessagingEndpoint(_authority) {
        if (_vault == address(0)) revert VaultUnset();
        vault = _vault;
    }

    // ========================================= ADMIN =========================================

    function setAssetWhitelisted(address[] calldata assets, bool allowed) external restricted {
        for (uint256 i; i < assets.length; i++) {
            assetWhitelisted[assets[i]] = allowed;
        }
    }

    // ========================================= USER =========================================

    function deposit(
        ERC20 asset,
        uint256 amount,
        uint64 toChainId,
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
        if (!assetWhitelisted[address(asset)]) revert AssetNotWhitelisted();

        shares = amount;
        SafeTransferLib.safeTransferFrom(address(asset), msg.sender, vault, amount);

        bytes32 toAccountId = TransitTokenLib.formatAccountId(toChainId, to);
        _sendMessage(
            _hubChainId(),
            messageGas,
            MessageType.Deposit,
            abi.encode(
                DepositMessage({ asset: address(asset), nonce: ++outboundNonce, amount: shares, toAccountId: toAccountId })
            )
        );

        emit Deposit(address(asset), msg.sender, toAccountId, amount);
    }

    function preApprove(Hub.Order calldata order, uint64 messageGas) external payable nonReentrant {
        _requireNotPaused();
        _sendMessage(_hubChainId(), messageGas, MessageType.PreApproval, abi.encode(msg.sender, order));
    }

    function requestOrderCancellation(
        Hub.OrderCancellationRequest calldata request,
        uint64 messageGas
    )
        external
        payable
        nonReentrant
    {
        _requireNotPaused();
        _sendMessage(
            _hubChainId(), messageGas, MessageType.OrderCancellationRequest, abi.encode(msg.sender, request)
        );
    }

    function requestTransfer(Hub.TransferRequest calldata request, uint64 messageGas) external payable nonReentrant {
        _requireNotPaused();
        _sendMessage(_hubChainId(), messageGas, MessageType.TransferRequest, abi.encode(msg.sender, request));
    }

    function requestWithdrawal(
        Hub.WithdrawalRequest calldata request,
        uint64 messageGas
    )
        external
        payable
        nonReentrant
    {
        _requireNotPaused();
        _sendMessage(_hubChainId(), messageGas, MessageType.WithdrawalRequest, abi.encode(msg.sender, request));
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
            WithdrawalMessage[] memory messages = abi.decode(body, (WithdrawalMessage[]));
            for (uint256 i; i < messages.length; i++) {
                _receiveWithdrawal(chainId, messages[i]);
            }
        } else {
            assert(false);
        }
    }

    function _receiveWithdrawal(uint64 sourceChainId, WithdrawalMessage memory message) internal {
        _consume(sourceChainId, message.nonce);

        _requireNotPaused();
        SafeTransferLib.safeTransferFrom(message.asset, vault, message.to, message.amount);
    }

}
