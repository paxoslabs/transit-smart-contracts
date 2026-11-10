// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.37;

import { ECDSA } from "solady/utils/ECDSA.sol";
import { FixedPointMathLib } from "solady/utils/FixedPointMathLib.sol";
import { IDepot } from "../depot/IDepot.sol";
import { TransitTokenLib } from "../helpers/TransitTokenLib.sol";
import { SwapConductor } from "./SwapConductor.sol";

contract SpotSwapConductor is SwapConductor {

    struct Order {
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
        bytes32 salt;
    }

    struct Fill {
        uint256 sellFilled;
        uint256 buyFilled;
    }

    struct Fee {
        bytes32 assetId;
        uint256 amount;
    }

    bytes32 public constant ORDER_TYPEHASH = keccak256(
        "Order(uint64 ownerChainId,address owner,bytes32 sellTokenId,bytes32 buyTokenId,uint256 sellAmount,uint256 buyAmount,uint64 receiverChainId,address receiver,uint256 expiresAt,bool partiallyFillable,bytes32 salt)"
    );

    constructor(
        address _authority,
        address _depot,
        bytes32 _surplusRecipientAccountId,
        address _turnstile
    )
        SwapConductor(_authority, _depot, _surplusRecipientAccountId, _turnstile)
    { }

    function _domainNameAndVersion() internal pure override returns (string memory, string memory) {
        return ("Transit SpotSwapConductor", "1");
    }

    // ========================================= USER =========================================

    /// TODO: Decide whether PreApproved should carry the full Order again.
    function preApprove(Order calldata order) external {
        bytes32 accountId = _senderAccountId();
        if (accountId != TransitTokenLib.formatAccountId(order.ownerChainId, order.owner)) revert NotOwner();
        bytes32 orderHash = hashOrder(order);
        preApproved[orderHash] = true;
        emit PreApproved(accountId, orderHash);
    }

    // ========================================= SOLVER =========================================

    function settle(
        uint256 epoch,
        Order[] calldata orders,
        bytes[] calldata signatures,
        Fill[] calldata fills,
        Fee[] calldata fees
    )
        external
        restricted
    {
        IDepot.TransferDelta[] memory deltas = new IDepot.TransferDelta[](orders.length * 2 + fees.length);
        if (orders.length != 0) {
            if (orders.length != signatures.length || orders.length != fills.length) revert LengthMismatch();
            (bytes32[] memory ownerAccountIds, bytes32[] memory orderHashes) = _checkOrders(orders, signatures, fills);
            _fillOrders(orders, fills, ownerAccountIds, orderHashes, deltas);
        }

        for (uint256 i; i < fees.length; i++) {
            Fee calldata fee = fees[i];
            deltas[orders.length * 2 + i] =
                IDepot.TransferDelta(bytes32(0), SURPLUS_RECIPIENT_ACCOUNT_ID, fee.assetId, fee.amount);
        }

        IDepot(DEPOT).transferAmong(deltas);

        IDepot(DEPOT).advanceEpoch(epoch);
    }

    function _checkOrders(
        Order[] calldata orders,
        bytes[] calldata signatures,
        Fill[] calldata fills
    )
        internal
        view
        returns (bytes32[] memory ownerAccountIds, bytes32[] memory orderHashes)
    {
        ownerAccountIds = new bytes32[](orders.length);
        orderHashes = new bytes32[](orders.length);
        uint256 lastEpochAdvancedAt = IDepot(DEPOT).lastEpochAdvancedAt();
        for (uint256 i; i < orders.length; i++) {
            Order calldata order = orders[i];
            bytes32 orderHash = hashOrder(order);
            orderHashes[i] = orderHash;
            ownerAccountIds[i] = TransitTokenLib.formatAccountId(order.ownerChainId, order.owner);

            if (order.expiresAt <= lastEpochAdvancedAt) revert Expired(orderHash);
            if (!order.partiallyFillable && fills[i].sellFilled != order.sellAmount) {
                revert NotPartiallyFillable(orderHash);
            }

            // Empty signature: pre-approved order. Otherwise ECDSA.
            if (signatures[i].length == 0) {
                if (!preApproved[orderHash]) revert NotPreApproved(orderHash);
            } else if (ECDSA.recoverCalldata(orderHash, signatures[i]) != order.owner) {
                revert BadSignature();
            }
        }
    }

    function _fillOrders(
        Order[] calldata orders,
        Fill[] calldata fills,
        bytes32[] memory ownerAccountIds,
        bytes32[] memory orderHashes,
        IDepot.TransferDelta[] memory deltas
    )
        internal
    {
        uint256 settlementEpoch = IDepot(DEPOT).settlementEpoch();
        for (uint256 i; i < orders.length; i++) {
            Order calldata order = orders[i];
            uint256 filled = filledAmount[orderHashes[i]] + fills[i].sellFilled;
            if (filled > order.sellAmount) revert Overfill(orderHashes[i]);
            filledAmount[orderHashes[i]] = filled;
            uint256 cancelled = cancelledFrom[ownerAccountIds[i]][orderHashes[i]];
            if (cancelled != 0 && settlementEpoch >= cancelled) revert Cancelled(orderHashes[i]);

            if (
                fills[i].buyFilled
                    < FixedPointMathLib.fullMulDivUp(fills[i].sellFilled, order.buyAmount, order.sellAmount)
            ) {
                revert LimitPrice(orderHashes[i]);
            }
            deltas[i] = IDepot.TransferDelta(ownerAccountIds[i], bytes32(0), order.sellTokenId, fills[i].sellFilled);
            deltas[orders.length + i] = IDepot.TransferDelta(
                bytes32(0),
                TransitTokenLib.formatAccountId(order.receiverChainId, order.receiver),
                order.buyTokenId,
                fills[i].buyFilled
            );

            emit Filled(orderHashes[i], ownerAccountIds[i], fills[i].sellFilled, fills[i].buyFilled);
        }
    }

    // ========================================= VIEWS =========================================

    function hashOrder(Order memory order) public view returns (bytes32) {
        return _hashTypedData(
            keccak256(
                abi.encode(
                    ORDER_TYPEHASH,
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
                    order.salt
                )
            )
        );
    }

}
