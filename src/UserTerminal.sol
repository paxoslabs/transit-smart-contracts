// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.37;

import { Hub } from "./Hub.sol";
import { ITurnstile } from "./ITurnstile.sol";
import { TransitTokenLib } from "./helpers/TransitTokenLib.sol";
import { TurnstileGated } from "./TurnstileGated.sol";

contract UserTerminal is TurnstileGated {

    Hub public immutable HUB;

    error NotOwner();
    error NotEffective();

    constructor(Hub _hub, address _turnstile) TurnstileGated(_turnstile) {
        HUB = _hub;
    }

    function requestOrderCancellation(Hub.OrderCancellationRequest calldata request) external {
        bytes32 accountId = _senderAccountId();
        if (accountId != TransitTokenLib.formatAccountId(request.ownerChainId, request.owner)) revert NotOwner();
        HUB.requestOrderCancellation(accountId, request);
    }

    function preApprove(Hub.Order calldata order) external {
        bytes32 accountId = _senderAccountId();
        if (accountId != TransitTokenLib.formatAccountId(order.ownerChainId, order.owner)) revert NotOwner();
        HUB.preApprove(accountId, order);
    }

    function reserve(bytes32 assetId, uint256 amount) external {
        HUB.reserve(_senderAccountId(), assetId, amount);
    }

    function reserveAndRequest(bytes32 requestId, bytes32 assetId, uint256 amount) external {
        HUB.reserveAndRequest(_senderAccountId(), requestId, assetId, amount);
    }

    function executeTransfer(Hub.TransferRequest calldata request) external {
        _requireEffective(request.ownerChainId, request.owner, HUB.hashTransferRequest(request));
        HUB.executeTransfer(_facilitated(), request);
    }

    function executeWithdrawal(Hub.WithdrawalRequest calldata request, uint64 messageGas) external payable {
        _requireEffective(request.ownerChainId, request.owner, HUB.hashWithdrawalRequest(request));
        uint256 amount = HUB.executeWithdrawal(_facilitated(), request);
        if (block.timestamp > request.deadline) return;
        (uint64 assetChainId, address asset) = TransitTokenLib.parseAssetId(request.assetId);
        ITurnstile(TURNSTILE).sendWithdrawalMessage{ value: msg.value }(
            assetChainId, messageGas, asset, amount, request.to
        );
    }

    function executeMint(Hub.MintRequest calldata request) external {
        _requireEffective(request.ownerChainId, request.owner, HUB.hashMintRequest(request));
        HUB.executeMint(_facilitated(), request);
    }

    function _requireEffective(uint64 ownerChainId, address owner, bytes32 requestId) private view {
        bytes32 ownerAccountId = TransitTokenLib.formatAccountId(ownerChainId, owner);
        if (_senderAccountId() == ownerAccountId) return;
        uint256 status = HUB.requestStatus(ownerAccountId, requestId);
        if (status == HUB.EXECUTED()) return;
        if (status == 0 || HUB.settlementEpoch() < status) revert NotEffective();
    }

}
