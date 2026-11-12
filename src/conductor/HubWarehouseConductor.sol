// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.37;

import { AccessManaged } from "@openzeppelin/contracts/access/manager/AccessManaged.sol";
import { IDepot } from "../depot/IDepot.sol";
import { Typehashes } from "../helpers/Typehashes.sol";
import { ITurnstile } from "../turnstile/ITurnstile.sol";
import { TransitTokenLib } from "../helpers/TransitTokenLib.sol";
import { RequestConductor } from "./RequestConductor.sol";

contract HubWarehouseConductor is AccessManaged, RequestConductor {

    event WithdrawalExecuted(bytes32 indexed requestId, uint256 amount);

    constructor(
        address _authority,
        address _depot,
        address _turnstile
    )
        AccessManaged(_authority)
        RequestConductor(_depot, _turnstile)
    { }

    function receiveDeposit(
        uint64 sourceChainId,
        address asset,
        uint256 amount,
        bytes32 fromAccountId,
        bytes32 toAccountId
    )
        external
        restricted
    {
        bytes32 assetId = TransitTokenLib.formatAssetId(sourceChainId, asset);
        IDepot(DEPOT).mint(fromAccountId, assetId, amount);
        if (fromAccountId == toAccountId) return;
        /// TODO: Decide reservation handling. transferFrom enforces depositor reservations, so an over-reserved
        /// depositor's transfer also fails and funds stay with the depositor.
        try IDepot(DEPOT).transferFrom(fromAccountId, toAccountId, assetId, amount) { } catch { }
    }

    function executeWithdrawal(ITurnstile.WithdrawalAction calldata action)
        external
        restricted
        returns (uint256 amount)
    {
        bytes32 requestId = hashWithdrawalAction(action);
        bytes32 accountId = _consume(action.ownerChainId, action.owner, requestId, action.assetId, action.amount);

        /// TODO: Decide expired-action handling. Currently consumes it and releases the reservation without moving
        /// funds.
        if (block.timestamp > action.deadline) {
            emit WithdrawalExecuted(requestId, 0);
            return 0;
        }

        amount = _fillAmount(accountId, action.assetId, action.amount, action.partiallyFillable);
        IDepot(DEPOT).burn(accountId, action.assetId, amount);

        emit WithdrawalExecuted(requestId, amount);
    }

    function hashWithdrawalAction(ITurnstile.WithdrawalAction memory action) public pure returns (bytes32) {
        return keccak256(
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
        );
    }

}
