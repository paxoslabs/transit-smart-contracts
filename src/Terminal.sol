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

    function settle(uint256 epoch, Hub.Fill[] calldata fills, Fee[] calldata fees) external restricted {
        Hub.TransferDelta[] memory deltas = new Hub.TransferDelta[](fills.length * 2 + fees.length);
        if (fills.length != 0) {
            bytes32[] memory orderHashes = HUB.fill(fills);

            for (uint256 i; i < fills.length; i++) {
                Hub.Fill calldata fill = fills[i];
                Hub.Order calldata order = fill.order;
                bytes32 orderHash = orderHashes[i];

                if (fill.buyFilled < FixedPointMathLib.fullMulDivUp(fill.sellFilled, order.buyAmount, order.sellAmount))
                {
                    revert LimitPrice(orderHash);
                }
                deltas[i] = Hub.TransferDelta(
                    order.owner, address(0), order.sellTokenChainId, order.sellToken, fill.sellFilled
                );
                deltas[fills.length + i] = Hub.TransferDelta(
                    address(0), order.receiver, order.buyTokenChainId, order.buyToken, fill.buyFilled
                );

                emit Filled(orderHash, order.owner, fill.sellFilled, fill.buyFilled);
            }
        }

        for (uint256 i; i < fees.length; i++) {
            Fee calldata fee = fees[i];
            deltas[fills.length * 2 + i] =
                Hub.TransferDelta(address(0), SURPLUS_RECIPIENT, fee.assetChainId, fee.asset, fee.amount);
        }

        HUB.transferAmong(deltas);

        HUB.advanceEpoch(epoch);
    }

}
