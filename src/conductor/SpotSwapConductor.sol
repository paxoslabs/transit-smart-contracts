// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.37;

import { FixedPointMathLib } from "solady/utils/FixedPointMathLib.sol";
import { IDepot } from "src/interfaces/IDepot.sol";
import { Typehashes } from "src/helpers/Typehashes.sol";
import { TransitAccountLib } from "src/helpers/TransitAccountLib.sol";
import { ISpotSwapConductor } from "src/interfaces/ISpotSwapConductor.sol";
import { SwapConductor } from "src/conductor/SwapConductor.sol";

/**
 * @title SpotSwapConductor
 * @notice Settles spot swaps: a solver matches signed orders and settles them atomically in the Depot each epoch.
 * Each fill burns the owner's sell token and mints the buy token to the receiver; per asset, mints must equal burns.
 * @dev Fees are minted to SURPLUS_RECIPIENT_ACCOUNT_ID and must be covered by surplus burns in the same batch (e.g.
 * price improvement), enforced by the Depot's zero-sum check.
 */
contract SpotSwapConductor is ISpotSwapConductor, SwapConductor {

    constructor(
        address _authority,
        address _depot,
        bytes28 _surplusRecipientAccountId,
        address _turnstile
    )
        SwapConductor(_authority, _depot, _surplusRecipientAccountId, _turnstile)
    { }

    function _domainNameAndVersion() internal pure override returns (string memory, string memory) {
        return ("Transit SpotSwapConductor", "1");
    }

    // ========================================= USER =========================================

    /// @inheritdoc ISpotSwapConductor
    function preApprove(Order calldata order) external {
        bytes28 accountId = _senderAccountId();
        if (accountId != TransitAccountLib.formatAccountId(order.ownerChainId, order.owner)) revert NotOwner();
        bytes32 orderHash = hashOrder(order);
        preApproved[orderHash] = true;
        emit PreApproved(accountId, orderHash, order);
    }

    // ========================================= SOLVER =========================================

    /// @inheritdoc ISpotSwapConductor
    function settle(uint256 epoch, OrderFill[] calldata orderFills, Fee[] calldata fees) external restricted {
        if (epoch != IDepot(DEPOT).settlementEpoch()) revert BadEpoch(epoch);
        // Each order produces two deltas (sell burn, buy mint), followed by one mint per fee.
        IDepot.TransferDelta[] memory deltas = new IDepot.TransferDelta[](orderFills.length * 2 + fees.length);

        // _fillOrders populates the deltas for orderFills.length * 2 (2 for each fill)
        _fillOrders(epoch, orderFills, deltas);

        for (uint256 i; i < fees.length; i++) {
            Fee calldata fee = fees[i];
            // Skip past the 2 * orderFills.length order slots to add fee deltas.
            deltas[orderFills.length * 2 + i] =
                IDepot.TransferDelta(bytes28(0), SURPLUS_RECIPIENT_ACCOUNT_ID, fee.assetId, fee.amount);
        }

        IDepot(DEPOT).transferAmong(deltas);

        IDepot(DEPOT).advanceEpoch();
    }

    /// @dev Validates each order (expiry, partial fill, signature, overfill, cancellation, limit price) and writes its
    /// two deltas.
    function _fillOrders(
        uint256 settlementEpoch,
        OrderFill[] calldata orderFills,
        IDepot.TransferDelta[] memory deltas
    )
        internal
    {
        uint256 lastEpochAdvancedAt = IDepot(DEPOT).lastEpochAdvancedAt();
        for (uint256 i; i < orderFills.length; i++) {
            Order calldata order = orderFills[i].order;
            Fill calldata fill = orderFills[i].fill;
            bytes32 orderHash = hashOrder(order);
            bytes28 ownerAccountId = TransitAccountLib.formatAccountId(order.ownerChainId, order.owner);

            if (order.expiresAt <= lastEpochAdvancedAt) revert Expired(orderHash);
            if (!order.partiallyFillable && fill.sellFilled != order.sellAmount) {
                revert NotPartiallyFillable(orderHash);
            }
            _verifySignature(orderHash, order.owner, orderFills[i].signature);
            _recordFill(orderHash, ownerAccountId, order.sellAmount, fill.sellFilled, fill.buyFilled, settlementEpoch);
            if (fill.buyFilled < FixedPointMathLib.fullMulDivUp(fill.sellFilled, order.buyAmount, order.sellAmount)) {
                revert LimitPrice(orderHash);
            }

            // Order i owns slots 2i (sell burn from owner) and 2i + 1 (buy mint to receiver).
            deltas[i * 2] = IDepot.TransferDelta(
                ownerAccountId,
                bytes28(0),
                TransitAccountLib.formatAccountId(order.sellTokenChainId, order.sellToken),
                fill.sellFilled
            );
            deltas[i * 2 + 1] = IDepot.TransferDelta(
                bytes28(0),
                TransitAccountLib.formatAccountId(order.receiverChainId, order.receiver),
                TransitAccountLib.formatAccountId(order.buyTokenChainId, order.buyToken),
                fill.buyFilled
            );
        }
    }

    // ========================================= VIEWS =========================================

    /// @inheritdoc ISpotSwapConductor
    function hashOrder(Order calldata order) public view returns (bytes32) {
        return _hashTypedData(keccak256(abi.encode(Typehashes.ORDER, order)));
    }

}
