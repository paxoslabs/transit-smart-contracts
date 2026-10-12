// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.37;

import { AccessManaged } from "@openzeppelin/contracts/access/manager/AccessManaged.sol";
import { FixedPointMathLib } from "solady/utils/FixedPointMathLib.sol";
import { Hub } from "./Hub.sol";
import { OrderRegistry } from "./OrderRegistry.sol";

contract Terminal is AccessManaged {

    using FixedPointMathLib for uint256;

    struct Fill {
        OrderRegistry.Order order;
        bytes signature;
        uint256 sellFilled;
        uint256 buyFilled;
    }

    struct Fee {
        address asset;
        uint64 assetChainId;
        uint256 amount;
    }

    uint256 public constant MAX_BPS = 10_000;

    Hub public immutable HUB;
    OrderRegistry public immutable ORDER_REGISTRY;
    address public immutable SURPLUS_RECIPIENT;

    uint256 public maxFeeSlippage;

    event Filled(bytes32 indexed orderHash, address indexed owner, uint256 sellFilled, uint256 buyFilled);

    error LimitPrice(bytes32 orderHash);

    constructor(
        address _authority,
        Hub _hub,
        OrderRegistry _orderRegistry,
        address _surplusRecipient
    )
        AccessManaged(_authority)
    {
        HUB = _hub;
        ORDER_REGISTRY = _orderRegistry;
        SURPLUS_RECIPIENT = _surplusRecipient;
    }

    function setMaxFeeSlippage(uint256 _maxFeeSlippage) external restricted {
        maxFeeSlippage = _maxFeeSlippage;
    }

    function settle(uint256 epoch, Fill[] calldata fills, Fee[] calldata fees) external restricted {
        Hub.TransferDelta[] memory deltas = new Hub.TransferDelta[](fills.length * 2 + fees.length);
        for (uint256 i; i < fills.length; i++) {
            Fill calldata fill = fills[i];
            OrderRegistry.Order calldata order = fill.order;
            (bytes32 orderHash, address owner) = ORDER_REGISTRY.fill(order, fill.signature, fill.sellFilled);

            if (
                fill.buyFilled
                    < fill.sellFilled
                        .fullMulDivUp(order.buyAmount, order.sellAmount)
                        .fullMulDivUp(MAX_BPS - maxFeeSlippage, MAX_BPS)
            ) {
                revert LimitPrice(orderHash);
            }
            deltas[i] = Hub.TransferDelta(owner, address(0), order.sellTokenChainId, order.sellToken, fill.sellFilled);
            deltas[fills.length + i] =
                Hub.TransferDelta(address(0), order.receiver, order.buyTokenChainId, order.buyToken, fill.buyFilled);

            emit Filled(orderHash, owner, fill.sellFilled, fill.buyFilled);
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
