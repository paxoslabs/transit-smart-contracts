// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.37;

import { AccessManaged } from "@openzeppelin/contracts/access/manager/AccessManaged.sol";
import { FixedPointMathLib } from "solady/utils/FixedPointMathLib.sol";
import { Hub } from "./Hub.sol";
import { TransitTokenLib } from "./helpers/TransitTokenLib.sol";

contract SwapTerminal is AccessManaged {

    struct Fee {
        bytes32 assetId;
        uint256 amount;
    }

    Hub public immutable HUB;
    bytes32 public immutable SURPLUS_RECIPIENT_ACCOUNT_ID;

    event Filled(bytes32 indexed orderHash, bytes32 indexed ownerAccountId, uint256 sellFilled, uint256 buyFilled);

    error LimitPrice(bytes32 orderHash);

    constructor(address _authority, Hub _hub, bytes32 _surplusRecipientAccountId) AccessManaged(_authority) {
        HUB = _hub;
        SURPLUS_RECIPIENT_ACCOUNT_ID = _surplusRecipientAccountId;
    }

    function settle(
        uint256 epoch,
        Hub.Order[] calldata orders,
        bytes[] calldata signatures,
        Hub.Fill[] calldata fills,
        Fee[] calldata fees
    )
        external
        restricted
    {
        Hub.TransferDelta[] memory deltas = new Hub.TransferDelta[](orders.length * 2 + fees.length);
        if (orders.length != 0) {
            bytes32[] memory orderHashes = HUB.facilitateFill(orders, signatures, fills);

            for (uint256 i; i < orders.length; i++) {
                Hub.Order calldata order = orders[i];

                if (
                    fills[i].buyFilled
                        < FixedPointMathLib.fullMulDivUp(fills[i].sellFilled, order.buyAmount, order.sellAmount)
                ) {
                    revert LimitPrice(orderHashes[i]);
                }
                bytes32 ownerAccountId = TransitTokenLib.formatAccountId(order.ownerChainId, order.owner);
                deltas[i] = Hub.TransferDelta(
                    ownerAccountId,
                    bytes32(0),
                    order.sellTokenId,
                    fills[i].sellFilled
                );
                deltas[orders.length + i] = Hub.TransferDelta(
                    bytes32(0),
                    TransitTokenLib.formatAccountId(order.receiverChainId, order.receiver),
                    order.buyTokenId,
                    fills[i].buyFilled
                );

                emit Filled(orderHashes[i], ownerAccountId, fills[i].sellFilled, fills[i].buyFilled);
            }
        }

        for (uint256 i; i < fees.length; i++) {
            Fee calldata fee = fees[i];
            deltas[orders.length * 2 + i] =
                Hub.TransferDelta(bytes32(0), SURPLUS_RECIPIENT_ACCOUNT_ID, fee.assetId, fee.amount);
        }

        HUB.transferAmong(deltas);

        HUB.advanceEpoch(epoch);
    }

}
