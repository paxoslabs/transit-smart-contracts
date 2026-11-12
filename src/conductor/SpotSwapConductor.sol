// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.37;

import { ECDSA } from "solady/utils/ECDSA.sol";
import { FixedPointMathLib } from "solady/utils/FixedPointMathLib.sol";
import { IDepot } from "../depot/IDepot.sol";
import { Typehashes } from "../helpers/Typehashes.sol";
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
        if (accountId != TransitTokenLib.formatAccountId(order.ownerChainId, order.owner, false)) revert NotOwner();
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
            _fillOrders(orders, signatures, fills, deltas);
        }

        for (uint256 i; i < fees.length; i++) {
            Fee calldata fee = fees[i];
            deltas[orders.length * 2 + i] =
                IDepot.TransferDelta(bytes32(0), SURPLUS_RECIPIENT_ACCOUNT_ID, fee.assetId, fee.amount);
        }

        IDepot(DEPOT).transferAmong(deltas);

        IDepot(DEPOT).advanceEpoch(epoch);
    }

    function _fillOrders(
        Order[] calldata orders,
        bytes[] calldata signatures,
        Fill[] calldata fills,
        IDepot.TransferDelta[] memory deltas
    )
        internal
    {
        uint256 lastEpochAdvancedAt = IDepot(DEPOT).lastEpochAdvancedAt();
        uint256 settlementEpoch = IDepot(DEPOT).settlementEpoch();
        for (uint256 i; i < orders.length; i++) {
            Order calldata order = orders[i];
            bytes32 orderHash = hashOrder(order);
            bytes32 ownerAccountId = TransitTokenLib.formatAccountId(order.ownerChainId, order.owner, false);

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

            _recordFill(
                orderHash, ownerAccountId, order.sellAmount, fills[i].sellFilled, fills[i].buyFilled, settlementEpoch
            );

            if (
                fills[i].buyFilled
                    < FixedPointMathLib.fullMulDivUp(fills[i].sellFilled, order.buyAmount, order.sellAmount)
            ) {
                revert LimitPrice(orderHash);
            }
            deltas[i] = IDepot.TransferDelta(ownerAccountId, bytes32(0), order.sellTokenId, fills[i].sellFilled);
            deltas[orders.length + i] = IDepot.TransferDelta(
                bytes32(0),
                TransitTokenLib.formatAccountId(order.receiverChainId, order.receiver, false),
                order.buyTokenId,
                fills[i].buyFilled
            );
        }
    }

    // ========================================= VIEWS =========================================

    function hashOrder(Order memory order) public view returns (bytes32) {
        return _hashTypedData(
            keccak256(
                abi.encode(
                    Typehashes.ORDER,
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
