// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.37;

import { IDepot } from "../depot/IDepot.sol";
import { Typehashes } from "../helpers/Typehashes.sol";
import { TransitTokenLib } from "../helpers/TransitTokenLib.sol";
import { RequestConductor } from "./RequestConductor.sol";

contract UserConductor is RequestConductor {

    struct TransferRequest {
        uint64 ownerChainId;
        address owner;
        uint64 toChainId;
        address to;
        bytes32 assetId;
        uint256 amount;
        uint256 deadline;
        bool partiallyFillable;
        bytes32 salt;
    }

    event TransferExecuted(bytes32 indexed requestId, uint256 amount);

    error ZeroAddress();

    constructor(address _depot, address _turnstile) RequestConductor(_depot, _turnstile) { }

    function reserve(bytes32 assetId, uint256 amount) external {
        IDepot(DEPOT).reserve(_senderAccountId(), assetId, amount);
    }

    function executeTransfer(TransferRequest calldata request) external {
        if (request.to == address(0)) revert ZeroAddress();
        bytes32 requestId = digestTransferRequest(request);
        bytes32 accountId = _consume(request.ownerChainId, request.owner, requestId, request.assetId, request.amount);

        /// TODO: Decide expired-request handling. Currently consumes it and releases the reservation without moving
        /// funds.
        if (block.timestamp > request.deadline) {
            emit TransferExecuted(requestId, 0);
            return;
        }

        uint256 amount = _fillAmount(accountId, request.assetId, request.amount, request.partiallyFillable);
        IDepot(DEPOT)
            .transferFrom(
                accountId,
                TransitTokenLib.formatAccountId(request.toChainId, request.to, false),
                request.assetId,
                amount
            );

        emit TransferExecuted(requestId, amount);
    }

    function digestTransferRequest(TransferRequest memory request) public pure returns (bytes32) {
        return keccak256(
            abi.encode(
                Typehashes.TRANSFER_REQUEST,
                request.ownerChainId,
                request.owner,
                request.toChainId,
                request.to,
                request.assetId,
                request.amount,
                request.deadline,
                request.partiallyFillable,
                request.salt
            )
        );
    }

}
