// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.37;

import { IDepot } from "src/depot/IDepot.sol";
import { Typehashes } from "src/helpers/Typehashes.sol";
import { TransitAccountLib } from "src/helpers/TransitAccountLib.sol";
import { RequestConductor } from "src/conductor/RequestConductor.sol";

contract UserConductor is RequestConductor {

    struct TransferRequest {
        uint64 ownerChainId;
        address owner;
        uint64 toChainId;
        address to;
        uint64 assetChainId;
        address asset;
        uint256 amount;
        uint256 deadline;
        bool partiallyFillable;
        bytes32 salt;
    }

    event TransferExecuted(bytes32 indexed requestId, uint256 amount);

    error ZeroAddress();

    constructor(address _depot, address _turnstile) RequestConductor(_depot, _turnstile) { }

    function requestTransfer(TransferRequest calldata request) external {
        _request(
            TransitAccountLib.formatAccountId(request.ownerChainId, request.owner),
            digestTransferRequest(request),
            TransitAccountLib.formatAccountId(request.assetChainId, request.asset),
            request.amount
        );
    }

    function executeTransfer(TransferRequest calldata request) external {
        if (request.to == address(0)) revert ZeroAddress();
        bytes32 requestId = digestTransferRequest(request);
        bytes28 accountId = TransitAccountLib.formatAccountId(request.ownerChainId, request.owner);
        bytes28 assetId = TransitAccountLib.formatAccountId(request.assetChainId, request.asset);
        _consume(accountId, requestId, assetId, request.amount);

        if (block.timestamp > request.deadline) {
            emit RequestExpired(requestId);
            return;
        }

        uint256 amount = _executableAmount(accountId, assetId, request.amount, request.partiallyFillable);
        IDepot(DEPOT)
            .transferFrom(accountId, TransitAccountLib.formatAccountId(request.toChainId, request.to), assetId, amount);

        emit TransferExecuted(requestId, amount);
    }

    function digestTransferRequest(TransferRequest memory request) public pure returns (bytes32) {
        return keccak256(abi.encode(Typehashes.TRANSFER_REQUEST, request));
    }

}
