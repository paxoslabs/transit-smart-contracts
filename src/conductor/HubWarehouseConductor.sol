// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.37;

import { AccessManaged } from "@openzeppelin/contracts/access/manager/AccessManaged.sol";
import { IDepot } from "src/depot/IDepot.sol";
import { Typehashes } from "src/helpers/Typehashes.sol";
import { ITurnstile } from "src/turnstile/ITurnstile.sol";
import { TransitAccountLib } from "src/helpers/TransitAccountLib.sol";
import { RequestConductor } from "src/conductor/RequestConductor.sol";

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

    function requestWithdrawal(ITurnstile.WithdrawalAction calldata action) external {
        _request(action.ownerChainId, action.owner, hashWithdrawalAction(action), action.assetId, action.amount);
    }

    function receiveDeposit(
        uint64 sourceChainId,
        address asset,
        uint256 amount,
        bytes28 fromAccountId,
        bytes28 toAccountId
    )
        external
        restricted
    {
        bytes28 assetId = TransitAccountLib.formatAccountId(sourceChainId, asset);
        bytes28 mintTo = toAccountId;
        if (!TransitAccountLib.isValid(toAccountId) || IDepot(DEPOT).addressFreezeList().isFrozen(fromAccountId)) {
            mintTo = fromAccountId;
        }
        IDepot(DEPOT).mint(mintTo, assetId, amount);
    }

    function executeWithdrawal(ITurnstile.WithdrawalAction calldata action)
        external
        restricted
        returns (uint256 amount)
    {
        bytes32 requestId = hashWithdrawalAction(action);
        bytes28 accountId = _consume(action.ownerChainId, action.owner, requestId, action.assetId, action.amount);

        if (block.timestamp > action.deadline) {
            emit RequestExpired(requestId);
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
