// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.37;

import { AccessManaged } from "@openzeppelin/contracts/access/manager/AccessManaged.sol";
import { FixedPointMathLib } from "solady/utils/FixedPointMathLib.sol";
import { IDepot } from "../depot/IDepot.sol";
import { ITurnstile } from "../turnstile/ITurnstile.sol";
import { TransitTokenLib } from "../helpers/TransitTokenLib.sol";
import { TurnstileGated } from "../turnstile/TurnstileGated.sol";
import { UserConductor } from "./UserConductor.sol";

contract HubWarehouseConductor is AccessManaged, TurnstileGated {

    struct WithdrawalRequest {
        uint64 ownerChainId;
        address owner;
        address to;
        bytes32 assetId;
        uint256 amount;
        uint256 deadline;
        bool partiallyFillable;
        bytes32 salt;
    }

    bytes32 public constant WITHDRAWAL_REQUEST_TYPEHASH = keccak256(
        "WithdrawalRequest(uint64 ownerChainId,address owner,address to,bytes32 assetId,uint256 amount,uint256 deadline,bool partiallyFillable,bytes32 salt)"
    );

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
        bytes32 toAccountId
    )
        external
        restricted
    {
        IDepot(DEPOT).mint(toAccountId, TransitTokenLib.formatAssetId(sourceChainId, asset), amount);
    }

    function executeWithdrawal(WithdrawalRequest calldata request, uint64 messageGas) external payable {
        bytes32 requestId = hashWithdrawalRequest(request);
        bytes32 accountId = _consume(request.ownerChainId, request.owner, requestId, request.assetId, request.amount);

        /// TODO: Decide expired-request handling. Currently consumes it and releases the reservation without moving
        /// funds.
        if (block.timestamp > request.deadline) {
            emit WithdrawalExecuted(requestId, 0);
            return;
        }

        uint256 amount = _fillAmount(accountId, request.assetId, request.amount, request.partiallyFillable);
        IDepot(DEPOT).burn(accountId, request.assetId, amount);

        (uint64 assetChainId, address asset) = TransitTokenLib.parseAssetId(request.assetId);
        ITurnstile(TURNSTILE).sendWithdrawalMessage{ value: msg.value }(
            assetChainId, messageGas, asset, amount, request.to
        );

        emit WithdrawalExecuted(requestId, amount);
    }

    function hashWithdrawalRequest(WithdrawalRequest memory request) public pure returns (bytes32) {
        return keccak256(
            abi.encode(
                WITHDRAWAL_REQUEST_TYPEHASH,
                request.ownerChainId,
                request.owner,
                request.to,
                request.assetId,
                request.amount,
                request.deadline,
                request.partiallyFillable,
                request.salt
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
        accountId = TransitTokenLib.formatAccountId(ownerChainId, owner);
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
        bytes32 ownerAccountId = TransitTokenLib.formatAccountId(ownerChainId, owner);
        if (_senderAccountId() == ownerAccountId) return;
        if (requestStatus[ownerAccountId][requestId] == EXECUTED) return;
        uint256 status = UserConductor(USER_CONDUCTOR).requestStatus(ownerAccountId, requestId);
        if (status == 0 || IDepot(DEPOT).settlementEpoch() < status) revert NotEffective();
    }

}
