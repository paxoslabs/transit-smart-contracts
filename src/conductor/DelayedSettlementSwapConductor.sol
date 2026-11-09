// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.37;

import { ECDSA } from "solady/utils/ECDSA.sol";
import { FixedPointMathLib } from "solady/utils/FixedPointMathLib.sol";
import { IDepot } from "../depot/IDepot.sol";
import { TransitTokenLib } from "../helpers/TransitTokenLib.sol";
import { SwapConductor } from "./SwapConductor.sol";

/**
 * @title DelayedSettlementSwapConductor
 * @notice A conductor to support delayed settlement swaps. Orders may be matched as normal in the transit orderbook.
 * However, orders marked delayedSettlement may have some settlementPeriod amount of time to come up with the money. A
 * penalty of amount/FILL_RATIO is applied if the payment is not made within this time
 * @custom:security-contact security@paxoslabs.com
 */
contract DelayedSettlementSwapConductor is SwapConductor {

    /// @dev Order object signed by user
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
        bool partiallyFillable;
        bool delayedSettlement;
        uint256 settlementPeriod;
        bytes32 salt;
    }

    /// @dev Settlement bot provided fill data. Fills are per pair of orders matched. A single order that is filling
    /// several others may have several PairedFills mentioning that order by orderIndex
    struct PairedFill {
        uint256[2] orderIndexes;
        uint256[2] amounts;
        uint256[2] fees;
    }

    /// @dev An escrow leg, they are saved in a mapping in pairs tied to an escrowId. This is the onchain log of a
    /// delayed settlements status
    struct Leg {
        bytes32 accountId;
        bytes32 receiverAccountId;
        bytes32 assetId;
        uint256 amount;
        uint256 owed;
        uint256 collateral;
        uint256 fee;
    }

    bytes32 public constant DELAYED_SETTLEMENT_ORDER_TYPEHASH = keccak256(
        "DelayedSettlementOrder(uint64 ownerChainId,address owner,bytes32 sellTokenId,bytes32 buyTokenId,uint256 sellAmount,uint256 buyAmount,uint64 receiverChainId,address receiver,uint256 expiresAt,bool partiallyFillable,bool delayedSettlement,uint256 settlementPeriod,bytes32 salt)"
    );

    uint256 public constant FILL_RATIO = 100;
    uint256 public constant MAX_SETTLEMENT_PERIOD = 1 days;

    bytes32 public immutable PENALTY_RECIPIENT_ACCOUNT_ID;

    uint256 public escrowCount;
    mapping(uint256 escrowId => Leg[2]) public escrowLegs;
    mapping(uint256 escrowId => uint256) public escrowDeadline;

    event Escrowed(uint256 indexed escrowId, bytes32 indexed firstOrderHash, bytes32 indexed secondOrderHash);
    event Repaid(uint256 indexed escrowId, uint256 side, uint256 amount);
    event Released(uint256 indexed escrowId);
    event Reclaimed(uint256 indexed escrowId);

    error BadPair(uint256 index);
    error SettlementPeriodOver();
    error SettlementPeriodActive();
    error NothingOwed();

    constructor(
        address _authority,
        address _depot,
        bytes32 _surplusRecipientAccountId,
        bytes32 _penaltyRecipientAccountId,
        address _turnstile
    )
        SwapConductor(_authority, _depot, _surplusRecipientAccountId, _turnstile)
    {
        PENALTY_RECIPIENT_ACCOUNT_ID = _penaltyRecipientAccountId;
    }

    function _domainNameAndVersion() internal pure override returns (string memory, string memory) {
        return ("Transit DelayedSettlementSwapConductor", "1");
    }

    // ========================================= USER =========================================

    /// @notice preApprove an order hash as  _senderAccountId to bypass need for offchain signatures
    function preApprove(DelayedSettlementOrder calldata order) external {
        bytes32 accountId = _senderAccountId();
        if (accountId != TransitTokenLib.formatAccountId(order.ownerChainId, order.owner)) revert NotOwner();
        bytes32 orderHash = hashOrder(order);
        preApproved[orderHash] = true;
        emit PreApproved(accountId, orderHash);
    }

    /// @notice repay a leg of an escrow. Must repay in full. If both sides have fully repaid upon this call _release()
    /// is called to distribute funds
    function repay(uint256 escrowId, uint256 side) external {
        if (block.timestamp > escrowDeadline[escrowId]) revert SettlementPeriodOver();
        // side will revert with out of bounds if > 1
        Leg storage leg = escrowLegs[escrowId][side];
        if (_senderAccountId() != leg.accountId) revert NotOwner();
        uint256 amount = leg.owed;
        if (amount == 0) revert NothingOwed();
        leg.owed = 0;

        IDepot(DEPOT).transferFrom(leg.accountId, _conductorAccountId(), leg.assetId, amount);
        emit Repaid(escrowId, side, amount);

        // since side must be 0 or 1: 1 - side results in whichever number side is not
        Leg storage counterparty = escrowLegs[escrowId][1 - side];
        if (counterparty.owed == 0) _release(escrowId);
    }

    /// @notice reclaim an array of escrowIds that have expired without recieving repayment
    function reclaim(uint256[] calldata escrowIds) external {
        for (uint256 i; i < escrowIds.length; i++) {
            _reclaim(escrowIds[i]);
        }
    }

    /// @dev internal function used in reclaim loop
    function _reclaim(uint256 escrowId) internal {
        // Cannot reclaim until escrowDeadline has passed
        if (block.timestamp <= escrowDeadline[escrowId]) revert SettlementPeriodActive();
        Leg[2] memory legs = escrowLegs[escrowId];
        delete escrowLegs[escrowId];
        delete escrowDeadline[escrowId];

        // reclaim each leg
        _reclaimLeg(legs[0]);
        _reclaimLeg(legs[1]);

        emit Reclaimed(escrowId);
    }

    /// @dev Helper used to reclaim a single leg. Run for both legs upon _reclaim
    function _reclaimLeg(Leg memory leg) internal {
        bytes32 conductorAccountId = _conductorAccountId();
        // If leg.owed == 0 then this leg was paid or was never a Delayed Settlement order to begin with. The funds must
        // be returned to the legs accountId.
        if (leg.owed == 0) {
            if (leg.amount != 0) {
                IDepot(DEPOT).transferFrom(conductorAccountId, leg.accountId, leg.assetId, leg.amount + leg.collateral);
            }
            // If leg.owed != 0 and the collateral != 0 then the leg was never paid off and the order has collateral
            // locked up. In this case the collateral must be taken to the PENALTY_RECIPIENT_ACCOUNT_ID
        } else if (leg.collateral != 0) {
            IDepot(DEPOT).transferFrom(conductorAccountId, PENALTY_RECIPIENT_ACCOUNT_ID, leg.assetId, leg.collateral);
        }
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

        IDepot.TransferDelta[] memory deltas = new IDepot.TransferDelta[](fills.length * 2);
        uint256[] memory sellFilled = new uint256[](orders.length);
        uint256[] memory buyFilled = new uint256[](orders.length);
        for (uint256 i; i < fills.length; i++) {
            PairedFill calldata fill = fills[i];
            _escrowFill(orders, fill, ownerAccountIds, orderHashes, i, deltas);

            sellFilled[fill.orderIndexes[0]] += fill.amounts[0];
            buyFilled[fill.orderIndexes[0]] += fill.amounts[1];
            sellFilled[fill.orderIndexes[1]] += fill.amounts[1];
            buyFilled[fill.orderIndexes[1]] += fill.amounts[0];
        }

        _fillOrders(orders, ownerAccountIds, orderHashes, sellFilled, buyFilled);

        IDepot(DEPOT).transferAmong(deltas);

        IDepot(DEPOT).advanceEpoch(epoch);
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
        IDepot.TransferDelta[] memory deltas
    )
        internal
    {
        DelayedSettlementOrder calldata first = orders[fill.orderIndexes[0]];
        DelayedSettlementOrder calldata second = orders[fill.orderIndexes[1]];
        if (
            fill.orderIndexes[0] == fill.orderIndexes[1] || (!first.delayedSettlement && !second.delayedSettlement)
                || first.sellTokenId != second.buyTokenId || first.buyTokenId != second.sellTokenId
                || fill.amounts[0] == 0 || fill.amounts[1] == 0
        ) {
            revert BadPair(index);
        }

        uint256 escrowId = ++escrowCount;
        escrowDeadline[escrowId] = block.timestamp + _settlementPeriod(first, second, index);
        deltas[index * 2] = _escrowLeg(orders, fill, ownerAccountIds, orderHashes, escrowId, 0);
        deltas[index * 2 + 1] = _escrowLeg(orders, fill, ownerAccountIds, orderHashes, escrowId, 1);

        emit Escrowed(escrowId, orderHashes[fill.orderIndexes[0]], orderHashes[fill.orderIndexes[1]]);
    }

    function _escrowLeg(
        DelayedSettlementOrder[] calldata orders,
        PairedFill calldata fill,
        bytes32[] memory ownerAccountIds,
        bytes32[] memory orderHashes,
        uint256 escrowId,
        uint256 side
    )
        internal
        returns (IDepot.TransferDelta memory)
    {
        uint256 orderIndex = fill.orderIndexes[side];
        DelayedSettlementOrder calldata order = orders[orderIndex];
        uint256 amount = fill.amounts[side];
        uint256 counterpartySide = 1 - side;
        if (
            fill.amounts[counterpartySide] - fill.fees[counterpartySide]
                < FixedPointMathLib.fullMulDivUp(amount, order.buyAmount, order.sellAmount)
        ) {
            revert LimitPrice(orderHashes[orderIndex]);
        }

        uint256 collateral = order.delayedSettlement ? FixedPointMathLib.divUp(amount, FILL_RATIO) : 0;
        escrowLegs[escrowId][side] = Leg({
            accountId: ownerAccountIds[orderIndex],
            receiverAccountId: TransitTokenLib.formatAccountId(order.receiverChainId, order.receiver),
            assetId: order.sellTokenId,
            amount: amount,
            owed: order.delayedSettlement ? amount : 0,
            collateral: collateral,
            fee: fill.fees[side]
        });
        return IDepot.TransferDelta(
            ownerAccountIds[orderIndex],
            _conductorAccountId(),
            order.sellTokenId,
            order.delayedSettlement ? collateral : amount
        );
    }

    function _settlementPeriod(
        DelayedSettlementOrder calldata first,
        DelayedSettlementOrder calldata second,
        uint256 index
    )
        internal
        pure
        returns (uint256 settlementPeriod)
    {
        settlementPeriod = first.delayedSettlement ? first.settlementPeriod : second.settlementPeriod;
        if (
            settlementPeriod > MAX_SETTLEMENT_PERIOD
                || (first.delayedSettlement && first.settlementPeriod > second.settlementPeriod)
                || (second.delayedSettlement && second.settlementPeriod > first.settlementPeriod)
        ) {
            revert BadPair(index);
        }
    }

    function _release(uint256 escrowId) internal {
        Leg[2] memory legs = escrowLegs[escrowId];
        delete escrowLegs[escrowId];
        delete escrowDeadline[escrowId];

        _releaseLeg(legs, 0);
        _releaseLeg(legs, 1);

        emit Released(escrowId);
    }

    function _releaseLeg(Leg[2] memory legs, uint256 side) internal {
        Leg memory leg = legs[side];
        Leg memory counterparty = legs[1 - side];
        bytes32 conductorAccountId = _conductorAccountId();
        IDepot(DEPOT)
            .transferFrom(conductorAccountId, counterparty.receiverAccountId, leg.assetId, leg.amount - leg.fee);
        if (leg.fee != 0) {
            IDepot(DEPOT).transferFrom(conductorAccountId, SURPLUS_RECIPIENT_ACCOUNT_ID, leg.assetId, leg.fee);
        }
        if (leg.collateral != 0) {
            IDepot(DEPOT).transferFrom(conductorAccountId, leg.accountId, leg.assetId, leg.collateral);
        }
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
        uint256 settlementEpoch = IDepot(DEPOT).settlementEpoch();
        for (uint256 i; i < orders.length; i++) {
            DelayedSettlementOrder calldata order = orders[i];
            bytes32 orderHash = orderHashes[i];
            if (!order.partiallyFillable && sellFilled[i] != order.sellAmount) revert NotPartiallyFillable(orderHash);
            _recordFill(orderHash, ownerAccountIds[i], order.sellAmount, sellFilled[i], buyFilled[i], settlementEpoch);
        }
    }

    function _conductorAccountId() internal view returns (bytes32) {
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
                    order.partiallyFillable,
                    order.delayedSettlement,
                    order.settlementPeriod,
                    order.salt
                )
            )
        );
    }

}
