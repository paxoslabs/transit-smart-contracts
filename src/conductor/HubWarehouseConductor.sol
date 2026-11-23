// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.37;

import { AccessManaged } from "@openzeppelin/contracts/access/manager/AccessManaged.sol";
import { IDepot } from "src/interfaces/IDepot.sol";
import { Typehashes } from "src/helpers/Typehashes.sol";
import { ITurnstile } from "src/interfaces/ITurnstile.sol";
import { TransitAddressLib } from "src/helpers/TransitAddressLib.sol";
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
 * @custom:security-contact security@paxoslabs.com
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
            TransitAddressLib.formatTransitAddress(action.ownerChainId, action.owner),
            hashWithdrawalAction(action),
            TransitAddressLib.formatTransitAddress(action.assetChainId, action.asset),
            action.amount
        );
    }

    /// @inheritdoc IHubWarehouseConductor
    function receiveDeposit(
        uint64 sourceChainId,
        address asset,
        uint256 amount,
        bytes28 fromAccountId,
        bytes28 toAccountId,
        uint256 facilitationFee,
        bytes28 feeReceiverAccountId
    )
        external
        restricted
    {
        bytes28 assetId = TransitAddressLib.formatTransitAddress(sourceChainId, asset);
        // A frozen sender must not move funds out by depositing to another account, so its deposit stays whole in its
        // own frozen account, where it cannot move and may be seized with Depot.forceTransferFrom. No fee is paid from
        // frozen funds.
        if (IDepot(DEPOT).addressFreezeList().isFrozen(fromAccountId)) {
            IDepot(DEPOT).mint(fromAccountId, assetId, amount);
            return;
        }
        IDepot(DEPOT).mint(toAccountId, assetId, amount);
        // The fee should never fail. If it does (e.g. a frozen recipient), the whole deposit reverts and the message is
        // left Failed for an admin to retry, so the fee is only ever taken alongside a credited deposit.
        if (facilitationFee != 0) {
            IDepot(DEPOT).transferFrom(toAccountId, feeReceiverAccountId, assetId, facilitationFee);
        }
    }

    /// @inheritdoc IHubWarehouseConductor
    function executeWithdrawal(ITurnstile.WithdrawalAction calldata action)
        external
        restricted
        returns (uint256 amount)
    {
        bytes32 requestId = hashWithdrawalAction(action);
        bytes28 accountId = TransitAddressLib.formatTransitAddress(action.ownerChainId, action.owner);
        bytes28 assetId = TransitAddressLib.formatTransitAddress(action.assetChainId, action.asset);
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
