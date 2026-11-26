// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.37;

import { FixedPointMathLib } from "solady/utils/FixedPointMathLib.sol";
import { IDepot } from "src/interfaces/IDepot.sol";
import { Typehashes } from "src/helpers/Typehashes.sol";
import { TransitAddressLib } from "src/helpers/TransitAddressLib.sol";
import { SwapConductor } from "src/conductor/SwapConductor.sol";
import { IDelayedSettlementSwapConductor } from "src/interfaces/IDelayedSettlementSwapConductor.sol";

/**
 * @title DelayedSettlementSwapConductor
 * @notice A conductor to support delayed settlement swaps. Orders may be matched as normal in the transit orderbook.
 * However, orders marked collateralized post only amount/FILL_RATIO as collateral and have some settlementPeriod
 * amount of time to come up with the rest. The collateral is forfeited as a penalty if the payment is not made within
 * this time. A pair with no collateralized order is fully funded at fill and is released in the same settle.
 * @custom:security-contact security@paxoslabs.com
 */
contract DelayedSettlementSwapConductor is IDelayedSettlementSwapConductor, SwapConductor {

    /// @inheritdoc IDelayedSettlementSwapConductor
    uint256 public constant FILL_RATIO = 100;
    /// @inheritdoc IDelayedSettlementSwapConductor
    uint256 public constant MAX_SETTLEMENT_PERIOD = 1 days;

    /// @inheritdoc IDelayedSettlementSwapConductor
    bytes28 public immutable PENALTY_RECIPIENT_ACCOUNT_ID;

    /// @inheritdoc IDelayedSettlementSwapConductor
    uint256 public escrowCount;
    /// @inheritdoc IDelayedSettlementSwapConductor
    mapping(uint256 escrowId => Leg[2]) public escrowLegs;
    /// @inheritdoc IDelayedSettlementSwapConductor
    mapping(uint256 escrowId => uint256) public escrowDeadline;

    constructor(
        address _authority,
        address _depot,
        bytes28 _surplusRecipientAccountId,
        bytes28 _penaltyRecipientAccountId,
        address _turnstile
    )
        SwapConductor(_authority, _depot, _surplusRecipientAccountId, _turnstile)
    {
        if (!TransitAddressLib.isValid(_penaltyRecipientAccountId)) revert InvalidAccount();
        PENALTY_RECIPIENT_ACCOUNT_ID = _penaltyRecipientAccountId;
    }

    function _domainNameAndVersion() internal pure override returns (string memory, string memory) {
        return ("Transit DelayedSettlementSwapConductor", "1");
    }

    // ========================================= USER =========================================

    /// @inheritdoc IDelayedSettlementSwapConductor
    function preApprove(DelayedSettlementOrder calldata order) external {
        bytes28 accountId = _senderAccountId();
        if (accountId != TransitAddressLib.formatTransitAddress(order.ownerChainId, order.owner)) revert NotOwner();
        bytes32 orderHash = hashOrder(order);
        preApproved[orderHash] = true;
        emit PreApproved(accountId, orderHash, order);
    }

    /// @inheritdoc IDelayedSettlementSwapConductor
    function repay(uint256 escrowId, uint256 side) external {
        if (block.timestamp > escrowDeadline[escrowId]) revert SettlementPeriodOver();
        // side will revert with out of bounds if > 1
        Leg storage leg = escrowLegs[escrowId][side];
        if (_senderAccountId() != leg.accountId) revert NotOwner();
        uint256 amount = leg.debt;
        if (amount == 0) revert NothingOwed();
        leg.debt = 0;

        IDepot(DEPOT).transferFrom(leg.accountId, _conductorAccountId(), leg.assetId, amount);
        emit Repaid(escrowId, side);

        // since side must be 0 or 1: 1 - side results in whichever number side is not
        Leg storage counterparty = escrowLegs[escrowId][1 - side];
        if (counterparty.debt == 0) _release(escrowId);
    }

    /// @inheritdoc IDelayedSettlementSwapConductor
    function reclaim(uint256[] calldata escrowIds) external {
        for (uint256 i; i < escrowIds.length; i++) {
            _reclaim(escrowIds[i]);
        }
    }

    /// @dev internal function used in reclaim loop
    function _reclaim(uint256 escrowId) internal {
        uint256 deadline = escrowDeadline[escrowId];
        // Skip closed or nonexistent escrows instead of reverting, so one front-run id can't revert a whole batch
        if (deadline == 0) return;
        // Cannot reclaim until escrowDeadline has passed
        if (block.timestamp <= deadline) revert SettlementPeriodActive();
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
        bytes28 conductorAccountId = _conductorAccountId();
        // If leg.debt == 0 then this leg was paid or was never a collateralized order to begin with. The funds must
        // be returned to the legs accountId.
        if (leg.debt == 0) {
            if (leg.amount != 0) {
                IDepot(DEPOT).transferFrom(conductorAccountId, leg.accountId, leg.assetId, leg.amount);
            }
            // If leg.debt != 0 and the collateral != 0 then the leg was never paid off and the order has collateral
            // held in escrow. In this case the collateral must be taken to the PENALTY_RECIPIENT_ACCOUNT_ID
        } else if (leg.collateral != 0) {
            IDepot(DEPOT).transferFrom(conductorAccountId, PENALTY_RECIPIENT_ACCOUNT_ID, leg.assetId, leg.collateral);
        }
    }

    // ========================================= SOLVER =========================================

    /// @inheritdoc IDelayedSettlementSwapConductor
    function settle(
        uint256 epoch,
        DelayedSettlementOrder[] calldata orders,
        bytes[] calldata signatures,
        PairedFill[] calldata fills
    )
        external
        restricted
    {
        if (epoch != IDepot(DEPOT).settlementEpoch()) revert BadEpoch(epoch);
        // Signatures must be provided for each order
        if (orders.length != signatures.length) revert LengthMismatch();
        (bytes28[] memory ownerAccountIds, bytes32[] memory orderHashes) = _checkOrders(orders, signatures);

        IDepot.TransferDelta[] memory deltas = new IDepot.TransferDelta[](fills.length * 2); // deltas come in 2 * fills
        // as they come in pairs
        uint256[] memory sellFilled = new uint256[](orders.length);
        uint256[] memory buyFilled = new uint256[](orders.length);
        // Escrow ids are assigned sequentially per fill, so fill i gets firstEscrowId + i
        uint256 firstEscrowId = escrowCount + 1;
        for (uint256 i; i < fills.length; i++) {
            PairedFill calldata fill = fills[i];
            // Populate the deltas in _escrowFill. These deltas applied in the Depot will preform the escrows
            _escrowFill(orders, fill, ownerAccountIds, orderHashes, i, deltas);

            // Note the fills for order indexes to handle partial fill matches
            sellFilled[fill.orderIndexes[0]] += fill.amounts[0];
            buyFilled[fill.orderIndexes[0]] += fill.amounts[1];
            sellFilled[fill.orderIndexes[1]] += fill.amounts[1];
            buyFilled[fill.orderIndexes[1]] += fill.amounts[0];
        }

        // Apply the fills to the filledAmount mapping
        _fillOrders(orders, ownerAccountIds, orderHashes, sellFilled, buyFilled);

        IDepot(DEPOT).transferAmong(deltas);

        // A pair with no collateralized order owes nothing, so it is released now that its funds are escrowed. This
        // can't happen in the fill loop above: the escrow deltas only land in the conductor account at transferAmong.
        for (uint256 i; i < fills.length; i++) {
            if (!orders[fills[i].orderIndexes[0]].collateralized && !orders[fills[i].orderIndexes[1]].collateralized) {
                _release(firstEscrowId + i);
            }
        }

        IDepot(DEPOT).advanceEpoch();
    }

    /// @dev Helper to check order expirations and signatures
    function _checkOrders(
        DelayedSettlementOrder[] calldata orders,
        bytes[] calldata signatures
    )
        internal
        view
        returns (bytes28[] memory ownerAccountIds, bytes32[] memory orderHashes)
    {
        ownerAccountIds = new bytes28[](orders.length);
        orderHashes = new bytes32[](orders.length);
        uint256 lastEpochAdvancedAt = IDepot(DEPOT).lastEpochAdvancedAt();
        for (uint256 i; i < orders.length; i++) {
            DelayedSettlementOrder calldata order = orders[i];
            bytes32 orderHash = hashOrder(order);
            orderHashes[i] = orderHash;
            ownerAccountIds[i] = TransitAddressLib.formatTransitAddress(order.ownerChainId, order.owner);

            if (order.expiresAt <= lastEpochAdvancedAt) revert Expired(orderHash);

            _verifySignature(orderHash, order.owner, signatures[i]);
        }
    }

    /// @dev Populates the deltas for escrow of Delayed Settlement. Also preforms checks on the provided PairedFills
    function _escrowFill(
        DelayedSettlementOrder[] calldata orders,
        PairedFill calldata fill,
        bytes28[] memory ownerAccountIds,
        bytes32[] memory orderHashes,
        uint256 index,
        IDepot.TransferDelta[] memory deltas
    )
        internal
    {
        DelayedSettlementOrder calldata first = orders[fill.orderIndexes[0]];
        DelayedSettlementOrder calldata second = orders[fill.orderIndexes[1]];
        // A pair may not:
        // - reference the same order for both pairs
        // - contain missmatched buy/sell tokens
        // - fill an amount of 0 on either order
        // - name an invalid receiver on either order
        if (
            fill.orderIndexes[0] == fill.orderIndexes[1] || first.sellTokenChainId != second.buyTokenChainId
                || first.sellToken != second.buyToken || first.buyTokenChainId != second.sellTokenChainId
                || first.buyToken != second.sellToken || fill.amounts[0] == 0 || fill.amounts[1] == 0
                || !TransitAddressLib.isValid(
                    TransitAddressLib.formatTransitAddress(first.receiverChainId, first.receiver)
                )
                || !TransitAddressLib.isValid(
                    TransitAddressLib.formatTransitAddress(second.receiverChainId, second.receiver)
                )
        ) {
            revert BadPair(index);
        }

        uint256 escrowId = ++escrowCount;
        escrowDeadline[escrowId] = block.timestamp + _settlementPeriod(first, second, index);
        // Create the delta and store the escrow leg in storage for each matched pair
        deltas[index * 2] = _escrowLeg(orders, fill, ownerAccountIds, orderHashes, escrowId, 0);
        deltas[index * 2 + 1] = _escrowLeg(orders, fill, ownerAccountIds, orderHashes, escrowId, 1);

        emit Escrowed(escrowId, orderHashes[fill.orderIndexes[0]], orderHashes[fill.orderIndexes[1]]);
    }

    /// @dev Helper to create the delta and store the escrow leg in storage for each matched pair
    function _escrowLeg(
        DelayedSettlementOrder[] calldata orders,
        PairedFill calldata fill,
        bytes28[] memory ownerAccountIds,
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
        bytes28 sellTokenId = TransitAddressLib.formatTransitAddress(order.sellTokenChainId, order.sellToken);
        uint256 counterpartySide = 1 - side;
        // If the amount the counterparty will provide - fees is < the required amount scaled to the size of the fill
        if (
            fill.amounts[counterpartySide] - fill.fees[counterpartySide]
                < FixedPointMathLib.fullMulDivUp(amount, order.buyAmount, order.sellAmount)
        ) {
            revert LimitPrice(orderHashes[orderIndex]);
        }

        // If the order is a DS order then the collateral required is equal to the amount / FILL_RATIO (rounded up)
        uint256 collateral = order.collateralized ? FixedPointMathLib.divUp(amount, FILL_RATIO) : 0;
        // Publish the Leg onchain to track the escrow
        escrowLegs[escrowId][side] = Leg({
            accountId: ownerAccountIds[orderIndex],
            receiverAccountId: TransitAddressLib.formatTransitAddress(order.receiverChainId, order.receiver),
            assetId: sellTokenId,
            amount: amount,
            debt: order.collateralized ? amount - collateral : 0,
            collateral: collateral,
            fee: fill.fees[side]
        });

        // Return the delta to transfer tokens in the Depot
        return IDepot.TransferDelta(
            ownerAccountIds[orderIndex], _conductorAccountId(), sellTokenId, order.collateralized ? collateral : amount
        );
    }

    /// @dev helper to determine 2 orders ideal settlement period
    /// This is determined by the collateralized order in the event that a collateralized & non-collateralized order are
    /// matched, and rejected if the non-collateralized order requested a shorter settlement period. If both are
    /// collateralized, they must have the same settlementPeriod specified
    function _settlementPeriod(
        DelayedSettlementOrder calldata first,
        DelayedSettlementOrder calldata second,
        uint256 index
    )
        internal
        pure
        returns (uint256 settlementPeriod)
    {
        if (!first.collateralized && !second.collateralized) return 0;
        settlementPeriod = first.collateralized ? first.settlementPeriod : second.settlementPeriod;
        if (
            settlementPeriod > MAX_SETTLEMENT_PERIOD
                || (first.collateralized && first.settlementPeriod > second.settlementPeriod)
                || (second.collateralized && second.settlementPeriod > first.settlementPeriod)
        ) {
            revert BadPair(index);
        }
    }

    /// @dev helper to _release an escrow
    function _release(uint256 escrowId) internal {
        Leg[2] memory legs = escrowLegs[escrowId];
        delete escrowLegs[escrowId];
        delete escrowDeadline[escrowId];

        // If either party is frozen by now, reclaim both legs and undo the transaction. By now in _release, all funds
        // will have been repaid so nobody will be penalized
        if (
            IDepot(DEPOT).addressFreezeList().isFrozen(legs[0].accountId)
                || IDepot(DEPOT).addressFreezeList().isFrozen(legs[1].accountId)
        ) {
            _reclaimLeg(legs[0]);
            _reclaimLeg(legs[1]);
            emit Reclaimed(escrowId);
            return;
        }

        _releaseLeg(legs, 0);
        _releaseLeg(legs, 1);

        emit Released(escrowId);
    }

    /// @dev helper to release a single leg
    function _releaseLeg(Leg[2] memory legs, uint256 side) internal {
        Leg memory leg = legs[side];
        Leg memory counterparty = legs[1 - side];
        bytes28 conductorAccountId = _conductorAccountId();

        // The depot must transfer from the escrow account to the counterparty - fees
        IDepot(DEPOT)
            .transferFrom(conductorAccountId, counterparty.receiverAccountId, leg.assetId, leg.amount - leg.fee);

        // If there was a fee, take the fee to the SURPLUS_RECIPIENT_ACCOUNT_ID
        if (leg.fee != 0) {
            IDepot(DEPOT).transferFrom(conductorAccountId, SURPLUS_RECIPIENT_ACCOUNT_ID, leg.assetId, leg.fee);
        }
    }

    /// @dev Helper to track fills as shown in parent SwapConductor according to this contract's Fill system
    function _fillOrders(
        DelayedSettlementOrder[] calldata orders,
        bytes28[] memory ownerAccountIds,
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

    /// @dev The escrow account is an account for this contract on this chain
    function _conductorAccountId() internal view returns (bytes28) {
        return TransitAddressLib.formatTransitAddress(uint64(block.chainid), address(this));
    }

    // ========================================= VIEWS =========================================

    /// @inheritdoc IDelayedSettlementSwapConductor
    function hashOrder(DelayedSettlementOrder memory order) public view returns (bytes32) {
        return _hashTypedData(keccak256(abi.encode(Typehashes.DELAYED_SETTLEMENT_ORDER, order)));
    }

}
