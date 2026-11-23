// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.37;

import { IDepot } from "src/interfaces/IDepot.sol";
import { Typehashes } from "src/helpers/Typehashes.sol";
import { TransitAddressLib } from "src/helpers/TransitAddressLib.sol";
import { RequestConductor } from "src/conductor/RequestConductor.sol";
import { IUserConductor } from "src/interfaces/IUserConductor.sol";

/**
 * @title UserConductor
 * @notice Lets users move their own Depot balances between accounts, including to accounts on other chains, without
 * leaving the ledger. A transfer is requested, waits one epoch, then may be executed by anyone.
 * @dev Built on RequestConductor: the request reserves the funds, and execution transfers up to the executable
 * amount. Expired requests are consumed without moving funds.
 * @custom:security-contact security@paxoslabs.com
 */
contract UserConductor is IUserConductor, RequestConductor {

    constructor(address _depot, address _turnstile) RequestConductor(_depot, _turnstile) { }

    /// @inheritdoc IUserConductor
    function requestTransfer(TransferRequest calldata request) external {
        _request(
            TransitAddressLib.formatTransitAddress(request.ownerChainId, request.owner),
            digestTransferRequest(request),
            TransitAddressLib.formatTransitAddress(request.assetChainId, request.asset),
            request.amount
        );
    }

    /// @inheritdoc IUserConductor
    function executeTransfer(TransferRequest calldata request) external {
        if (request.to == address(0)) revert ZeroAddress();
        bytes32 requestId = digestTransferRequest(request);
        bytes28 accountId = TransitAddressLib.formatTransitAddress(request.ownerChainId, request.owner);
        bytes28 assetId = TransitAddressLib.formatTransitAddress(request.assetChainId, request.asset);
        _consume(accountId, requestId, assetId, request.amount);

        if (block.timestamp > request.deadline) {
            emit RequestExpired(requestId);
            return;
        }

        uint256 amount = _executableAmount(accountId, assetId, request.amount, request.partiallyFillable);
        bytes28 toAccountId = TransitAddressLib.formatTransitAddress(request.toChainId, request.to);
        IDepot(DEPOT).transferFrom(accountId, toAccountId, assetId, amount);

        emit TransferExecuted(requestId, amount);
    }

    /// @inheritdoc IUserConductor
    function digestTransferRequest(TransferRequest memory request) public pure returns (bytes32) {
        return keccak256(abi.encode(Typehashes.TRANSFER_REQUEST, request));
    }

}
