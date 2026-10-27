// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.37;

import { ECDSA } from "solady/utils/ECDSA.sol";
import { FixedPointMathLib } from "solady/utils/FixedPointMathLib.sol";
import { Depot } from "../Depot.sol";
import { TransitTokenLib } from "../helpers/TransitTokenLib.sol";
import { SwapTerminal } from "./SwapTerminal.sol";

contract DelayedSettlementSwapTerminal is SwapTerminal {

    /// TODO: Decide the name of `collateralized` (true: posts sellAmount / FILL_RATIO now, delivers sellAmount later).
    struct DelayedSettlementOrder {
        uint64 ownerChainId;
        address owner;
        bytes32 sellTokenId;
        bytes32 buyTokenId;
        uint256 sellAmount;
        uint256 buyAmount;
        uint64 receiverChainId;
        address receiver;
        uint256 expiresAt;
        bytes32 salt;
        bool partiallyFillable;
        bool collateralized;
    }

    struct PairedFill {
        uint256[2] indexes;
        uint256[2] amounts;
    }

    struct Leg {
        bytes32 accountId;
        bytes32 receiverAccountId;
        bytes32 assetId;
        uint256 amount;
        uint256 owed;
        uint256 collateral;
    }

    bytes32 public constant DELAYED_SETTLEMENT_ORDER_TYPEHASH = keccak256(
        "DelayedSettlementOrder(uint64 ownerChainId,address owner,bytes32 sellTokenId,bytes32 buyTokenId,uint256 sellAmount,uint256 buyAmount,uint64 receiverChainId,address receiver,uint256 expiresAt,bytes32 salt,bool partiallyFillable,bool collateralized)"
    );

    uint256 public constant FILL_RATIO = 100;
    uint256 public constant SETTLEMENT_PERIOD = 30 minutes;

    uint256 public escrowCount;
    mapping(uint256 escrowId => Leg[2]) public escrowLegs;
    mapping(uint256 escrowId => uint256) public escrowDeadline;

    event Escrowed(uint256 indexed escrowId, bytes32 indexed firstOrderHash, bytes32 indexed secondOrderHash);
    event Repaid(uint256 indexed escrowId, uint256 side, uint256 amount);
    event Released(uint256 indexed escrowId);
    event Reclaimed(uint256 indexed escrowId);

    error BadPair(uint256 index);
    error ExceedsOwed();
    error SettlementPeriodOver();
    error SettlementPeriodActive();

    constructor(
        address _authority,
        Depot _depot,
        bytes32 _surplusRecipientAccountId,
        address _turnstile
    )
        SwapTerminal(_authority, _depot, _surplusRecipientAccountId, _turnstile)
    { }

    /// TODO: Decide the EIP712 domain name and version. Currently "Transit Delayed Settlement" and "1".
    function _domainNameAndVersion() internal pure override returns (string memory, string memory) {
        return ("Transit Delayed Settlement", "1");
    }

    // ========================================= USER =========================================

    function preApprove(DelayedSettlementOrder calldata order) external {
        bytes32 accountId = _senderAccountId();
        if (accountId != TransitTokenLib.formatAccountId(order.ownerChainId, order.owner)) revert NotOwner();
        bytes32 orderHash = hashOrder(order);
        preApproved[orderHash] = true;
        emit PreApproved(accountId, orderHash);
    }

    /// TODO: Decide who may call repay. Currently anyone; it pulls from the leg's account.
    function repay(uint256 escrowId, uint256 side, uint256 amount) external nonReentrant {
        if (block.timestamp > escrowDeadline[escrowId]) revert SettlementPeriodOver();
        Leg storage leg = escrowLegs[escrowId][side];
        if (amount > leg.owed) revert ExceedsOwed();
        leg.owed -= amount;

        DEPOT.transferFrom(leg.accountId, _terminalAccountId(), leg.assetId, amount);
        emit Repaid(escrowId, side, amount);

        if (leg.owed == 0 && escrowLegs[escrowId][1 - side].owed == 0) _release(escrowId);
    }

    function reclaim(uint256 escrowId) external nonReentrant {
        if (block.timestamp <= escrowDeadline[escrowId]) revert SettlementPeriodActive();
        Leg[2] memory legs = escrowLegs[escrowId];
        delete escrowLegs[escrowId];
        delete escrowDeadline[escrowId];

        bytes32 terminalAccountId = _terminalAccountId();
        for (uint256 s; s < 2; s++) {
            Leg memory leg = legs[s];
            uint256 delivered = leg.amount - leg.owed;
            if (delivered != 0) DEPOT.transferFrom(terminalAccountId, leg.accountId, leg.assetId, delivered);
            if (leg.collateral != 0) {
                DEPOT.transferFrom(
                    terminalAccountId,
                    leg.owed == 0 ? leg.accountId : SURPLUS_RECIPIENT_ACCOUNT_ID,
                    leg.assetId,
                    leg.collateral
                );
            }
        }

        emit Reclaimed(escrowId);
    }

    // ========================================= SOLVER =========================================

    function settle(
        uint256 epoch,
        DelayedSettlementOrder[] calldata orders,
        bytes[] calldata signatures,
        PairedFill[] calldata fills
    )
        external
        restricted
    {
        if (orders.length != signatures.length) revert LengthMismatch();
        (bytes32[] memory ownerAccountIds, bytes32[] memory orderHashes) = _checkOrders(orders, signatures);

        Depot.TransferDelta[] memory deltas = new Depot.TransferDelta[](fills.length * 2);
        uint256[] memory sellFilled = new uint256[](orders.length);
        uint256[] memory buyFilled = new uint256[](orders.length);
        for (uint256 i; i < fills.length; i++) {
            PairedFill calldata fill = fills[i];
            _escrowFill(orders, fill, ownerAccountIds, orderHashes, i, deltas);

            sellFilled[fill.indexes[0]] += fill.amounts[0];
            buyFilled[fill.indexes[0]] += fill.amounts[1];
            sellFilled[fill.indexes[1]] += fill.amounts[1];
            buyFilled[fill.indexes[1]] += fill.amounts[0];
        }

        _fillOrders(orders, ownerAccountIds, orderHashes, sellFilled, buyFilled);

        DEPOT.transferAmong(deltas);

        DEPOT.advanceEpoch(epoch);
    }

    function _checkOrders(
        DelayedSettlementOrder[] calldata orders,
        bytes[] calldata signatures
    )
        internal
        view
        returns (bytes32[] memory ownerAccountIds, bytes32[] memory orderHashes)
    {
        ownerAccountIds = new bytes32[](orders.length);
        orderHashes = new bytes32[](orders.length);
        for (uint256 i; i < orders.length; i++) {
            DelayedSettlementOrder calldata order = orders[i];
            bytes32 orderHash = hashOrder(order);
            orderHashes[i] = orderHash;
            ownerAccountIds[i] = TransitTokenLib.formatAccountId(order.ownerChainId, order.owner);

            if (block.timestamp > order.expiresAt) revert Expired(orderHash);

            // Empty signature: pre-approved order. Otherwise ECDSA.
            if (signatures[i].length == 0) {
                if (!preApproved[orderHash]) revert NotPreApproved(orderHash);
            } else if (ECDSA.recoverCalldata(orderHash, signatures[i]) != order.owner) {
                revert BadSignature();
            }
        }
    }

    function _escrowFill(
        DelayedSettlementOrder[] calldata orders,
        PairedFill calldata fill,
        bytes32[] memory ownerAccountIds,
        bytes32[] memory orderHashes,
        uint256 index,
        Depot.TransferDelta[] memory deltas
    )
        internal
    {
        DelayedSettlementOrder calldata first = orders[fill.indexes[0]];
        DelayedSettlementOrder calldata second = orders[fill.indexes[1]];
        if (
            fill.indexes[0] == fill.indexes[1] || (!first.collateralized && !second.collateralized)
                || first.sellTokenId != second.buyTokenId || first.buyTokenId != second.sellTokenId
        ) {
            revert BadPair(index);
        }

        uint256 escrowId = ++escrowCount;
        escrowDeadline[escrowId] = block.timestamp + SETTLEMENT_PERIOD;
        bytes32 terminalAccountId = _terminalAccountId();
        for (uint256 s; s < 2; s++) {
            uint256 orderIndex = fill.indexes[s];
            DelayedSettlementOrder calldata order = orders[orderIndex];
            uint256 amount = fill.amounts[s];
            if (fill.amounts[1 - s] < FixedPointMathLib.fullMulDivUp(amount, order.buyAmount, order.sellAmount)) {
                revert LimitPrice(orderHashes[orderIndex]);
            }

            uint256 collateral = order.collateralized ? FixedPointMathLib.divUp(amount, FILL_RATIO) : 0;
            escrowLegs[escrowId][s] = Leg({
                accountId: ownerAccountIds[orderIndex],
                receiverAccountId: TransitTokenLib.formatAccountId(order.receiverChainId, order.receiver),
                assetId: order.sellTokenId,
                amount: amount,
                owed: order.collateralized ? amount : 0,
                collateral: collateral
            });
            deltas[index * 2 + s] = Depot.TransferDelta(
                ownerAccountIds[orderIndex], terminalAccountId, order.sellTokenId, order.collateralized ? collateral : amount
            );
        }

        emit Escrowed(escrowId, orderHashes[fill.indexes[0]], orderHashes[fill.indexes[1]]);
    }

    function _release(uint256 escrowId) internal {
        Leg[2] memory legs = escrowLegs[escrowId];
        delete escrowLegs[escrowId];
        delete escrowDeadline[escrowId];

        bytes32 terminalAccountId = _terminalAccountId();
        for (uint256 s; s < 2; s++) {
            DEPOT.transferFrom(terminalAccountId, legs[1 - s].receiverAccountId, legs[s].assetId, legs[s].amount);
            if (legs[s].collateral != 0) {
                DEPOT.transferFrom(terminalAccountId, legs[s].accountId, legs[s].assetId, legs[s].collateral);
            }
        }

        emit Released(escrowId);
    }

    function _fillOrders(
        DelayedSettlementOrder[] calldata orders,
        bytes32[] memory ownerAccountIds,
        bytes32[] memory orderHashes,
        uint256[] memory sellFilled,
        uint256[] memory buyFilled
    )
        internal
    {
        uint256 settlementEpoch = DEPOT.settlementEpoch();
        for (uint256 i; i < orders.length; i++) {
            DelayedSettlementOrder calldata order = orders[i];
            bytes32 orderHash = orderHashes[i];
            if (!order.partiallyFillable && sellFilled[i] != order.sellAmount) revert NotPartiallyFillable(orderHash);
            uint256 filled = filledAmount[orderHash] + sellFilled[i];
            if (filled > order.sellAmount) revert Overfill(orderHash);
            filledAmount[orderHash] = filled;
            uint256 cancelled = cancelledFrom[ownerAccountIds[i]][orderHash];
            if (cancelled != 0 && settlementEpoch >= cancelled) revert Cancelled(orderHash);

            emit Filled(orderHash, ownerAccountIds[i], sellFilled[i], buyFilled[i]);
        }
    }

    function _terminalAccountId() internal view returns (bytes32) {
        return TransitTokenLib.formatAccountId(uint64(block.chainid), address(this));
    }

    // ========================================= VIEWS =========================================

    function hashOrder(DelayedSettlementOrder memory order) public view returns (bytes32) {
        return _hashTypedData(
            keccak256(
                abi.encode(
                    DELAYED_SETTLEMENT_ORDER_TYPEHASH,
                    order.ownerChainId,
                    order.owner,
                    order.sellTokenId,
                    order.buyTokenId,
                    order.sellAmount,
                    order.buyAmount,
                    order.receiverChainId,
                    order.receiver,
                    order.expiresAt,
                    order.salt,
                    order.partiallyFillable,
                    order.collateralized
                )
            )
        );
    }

}
