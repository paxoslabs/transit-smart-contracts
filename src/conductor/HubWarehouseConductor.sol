// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.37;

import { AccessManaged } from "@openzeppelin/contracts/access/manager/AccessManaged.sol";
import { IDepot } from "src/interfaces/IDepot.sol";
import { Typehashes } from "src/helpers/Typehashes.sol";
import { ITurnstile } from "src/interfaces/ITurnstile.sol";
import { TransitAccountLib } from "src/helpers/TransitAccountLib.sol";
import { RequestConductor } from "src/conductor/RequestConductor.sol";
import { IHubWarehouseConductor } from "src/interfaces/IHubWarehouseConductor.sol";

/**
 * @title HubWarehouseConductor
 * @notice Hub-side bridge between the spoke Turnstiles' custody and the Depot ledger. Deposits held in a spoke VAULT
 * are minted into the Depot; withdrawals burn Depot balance so the Turnstile can release tokens from the spoke VAULT.
 * @dev receiveDeposit and executeWithdrawal are restricted to the Turnstile, so balance is minted only for proven
 * custody validated by turnstile and tokens are released only by the turnstile after performing a burn using
 * recieveWithdrawal. requestWithdrawal is open to the owner but only reserves
 * funds; the withdrawal completes through the Turnstile once the request is effective, or immediately for a
 * facilitated owner.
 */
contract HubWarehouseConductor is IHubWarehouseConductor, AccessManaged, RequestConductor {

    constructor(
        address _authority,
        address _depot,
        address _turnstile
    )
        AccessManaged(_authority)
        RequestConductor(_depot, _turnstile)
    { }

    /// @inheritdoc IHubWarehouseConductor
    function requestWithdrawal(ITurnstile.WithdrawalAction calldata action) external {
        _request(
            TransitAccountLib.formatAccountId(action.ownerChainId, action.owner),
            hashWithdrawalAction(action),
            TransitAccountLib.formatAccountId(action.assetChainId, action.asset),
            action.amount
        );
    }

    /// @inheritdoc IHubWarehouseConductor
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
        // Tokens are already held on the spoke, so the deposit must be credited somewhere rather than revert. A
        // frozen sender must not move funds out by depositing to another account, so its deposit stays in its own
        // frozen account, where it cannot move and may be seized with Depot.forceTransferFrom.
        bytes28 mintTo = toAccountId;
        if (IDepot(DEPOT).addressFreezeList().isFrozen(fromAccountId)) mintTo = fromAccountId;
        IDepot(DEPOT).mint(mintTo, assetId, amount);
    }

    /// @inheritdoc IHubWarehouseConductor
    function executeWithdrawal(ITurnstile.WithdrawalAction calldata action)
        external
        restricted
        returns (uint256 amount)
    {
        bytes32 requestId = hashWithdrawalAction(action);
        bytes28 accountId = TransitAccountLib.formatAccountId(action.ownerChainId, action.owner);
        bytes28 assetId = TransitAccountLib.formatAccountId(action.assetChainId, action.asset);
        _consume(accountId, requestId, assetId, action.amount);

        if (block.timestamp > action.deadline) {
            emit RequestExpired(requestId);
            return 0;
        }

        amount = _executableAmount(accountId, assetId, action.amount, action.partiallyFillable);
        IDepot(DEPOT).burn(accountId, assetId, amount);

        emit WithdrawalExecuted(requestId, amount);
    }

    /// @inheritdoc IHubWarehouseConductor
    function hashWithdrawalAction(ITurnstile.WithdrawalAction memory action) public pure returns (bytes32) {
        return keccak256(abi.encode(Typehashes.WITHDRAWAL_ACTION, action));
    }

}
