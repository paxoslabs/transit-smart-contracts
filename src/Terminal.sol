// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.37;

import { AccessManaged } from "@openzeppelin/contracts/access/manager/AccessManaged.sol";
import { FixedPointMathLib } from "solady/utils/FixedPointMathLib.sol";
import { Hub } from "./Hub.sol";

contract Terminal is AccessManaged {

    struct Fee {
        address asset;
        uint64 assetChainId;
        uint256 amount;
    }

    Hub public immutable HUB;
    address public immutable SURPLUS_RECIPIENT;

    event Filled(bytes32 indexed orderHash, address indexed owner, uint256 sellFilled, uint256 buyFilled);

    error LimitPrice(bytes32 orderHash);

    constructor(address _authority, Hub _hub, address _surplusRecipient) AccessManaged(_authority) {
        HUB = _hub;
        SURPLUS_RECIPIENT = _surplusRecipient;
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
                deltas[i] = Hub.TransferDelta(
                    order.owner, address(0), order.sellTokenChainId, order.sellToken, fills[i].sellFilled
                );
                deltas[orders.length + i] = Hub.TransferDelta(
                    address(0), order.receiver, order.buyTokenChainId, order.buyToken, fills[i].buyFilled
                );

                emit Filled(orderHashes[i], order.owner, fills[i].sellFilled, fills[i].buyFilled);
            }
        }

        for (uint256 i; i < fees.length; i++) {
            Fee calldata fee = fees[i];
            deltas[orders.length * 2 + i] =
                Hub.TransferDelta(address(0), SURPLUS_RECIPIENT, fee.assetChainId, fee.asset, fee.amount);
        }

        HUB.transferAmong(deltas);

        HUB.advanceEpoch(epoch);
    }

}
