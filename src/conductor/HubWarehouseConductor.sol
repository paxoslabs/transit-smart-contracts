// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.37;

import { AccessManaged } from "@openzeppelin/contracts/access/manager/AccessManaged.sol";
import { FixedPointMathLib } from "solady/utils/FixedPointMathLib.sol";
import { IDepot } from "../depot/IDepot.sol";
import { Typehashes } from "../helpers/Typehashes.sol";
import { ITurnstile } from "../turnstile/ITurnstile.sol";
import { TransitTokenLib } from "../helpers/TransitTokenLib.sol";
import { TurnstileGated } from "../turnstile/TurnstileGated.sol";
import { UserConductor } from "./UserConductor.sol";

contract HubWarehouseConductor is AccessManaged, TurnstileGated {

    uint256 public constant EXECUTED = type(uint256).max;

    address public immutable DEPOT;
    address public immutable USER_CONDUCTOR;

    mapping(bytes32 accountId => mapping(bytes32 requestId => uint256 status)) public requestStatus;

    event WithdrawalExecuted(bytes32 indexed requestId, uint256 amount);

    error RequestReplay();
    error NotEffective();
    error InsufficientBalance();

    constructor(
        address _authority,
        address _depot,
        address _userConductor,
        address _turnstile
    )
        AccessManaged(_authority)
        TurnstileGated(_turnstile)
    {
        DEPOT = _depot;
        USER_CONDUCTOR = _userConductor;
    }

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

    function _consume(
        uint64 ownerChainId,
        address owner,
        bytes32 requestId,
        bytes32 assetId,
        uint256 amount
    )
        private
        returns (bytes32 accountId)
    {
        _requireEffective(ownerChainId, owner, requestId);
        accountId = TransitTokenLib.formatAccountId(ownerChainId, owner, false);
        if (requestStatus[accountId][requestId] == EXECUTED) revert RequestReplay();
        requestStatus[accountId][requestId] = EXECUTED;
        if (!_facilitated()) IDepot(DEPOT).release(accountId, assetId, amount);
    }

    /// TODO: Decide partial-fill cap. Uses raw balanceOf as before, but transferFrom/burn now also enforce other
    /// reservations and revert InsufficientBalance.
    function _fillAmount(
        bytes32 accountId,
        bytes32 assetId,
        uint256 requested,
        bool partiallyFillable
    )
        private
        view
        returns (uint256 amount)
    {
        amount = FixedPointMathLib.min(requested, IDepot(DEPOT).balanceOf(accountId, assetId));
        if (!partiallyFillable && amount < requested) revert InsufficientBalance();
    }

    /// TODO: Decide request-state ownership. Currently effectiveness is read from UserConductor.requestStatus (set by
    /// reserveAndRequest) and execution is tracked here.
    function _requireEffective(uint64 ownerChainId, address owner, bytes32 requestId) private view {
        bytes32 ownerAccountId = TransitTokenLib.formatAccountId(ownerChainId, owner, false);
        if (_senderAccountId() == ownerAccountId) return;
        if (requestStatus[ownerAccountId][requestId] == EXECUTED) return;
        uint256 status = UserConductor(USER_CONDUCTOR).requestStatus(ownerAccountId, requestId);
        if (status == 0 || IDepot(DEPOT).settlementEpoch() < status) revert NotEffective();
    }

}
