// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.37;

import { AccessManaged } from "@openzeppelin/contracts/access/manager/AccessManaged.sol";
import { EIP712 } from "solady/utils/EIP712.sol";
import { ECDSA } from "solady/utils/ECDSA.sol";
import { Hub } from "./warehouse/Hub.sol";

contract Terminal is AccessManaged, EIP712 {

    /// TODO: Decide the remaining Order fields. validTo is the obvious candidate.
    struct Order {
        uint64 sellTokenChainId;
        address sellToken;
        uint64 buyTokenChainId;
        address buyToken;
        uint256 sellAmount;
        uint256 buyAmount;
        address receiver;
        bytes32 salt;
        bool partiallyFillable;
    }

    struct Fill {
        Order order;
        bytes signature;
        uint256 sellFilled;
        uint256 buyFilled;
    }

    bytes32 public constant ORDER_TYPEHASH = keccak256(
        "Order(uint64 sellTokenChainId,address sellToken,uint64 buyTokenChainId,address buyToken,uint256 sellAmount,uint256 buyAmount,address receiver,bytes32 salt,bool partiallyFillable)"
    );

    Hub public immutable HUB;
    address public immutable SURPLUS_RECIPIENT;

    mapping(bytes32 orderHash => uint256) public filledAmount;

    event Filled(bytes32 indexed orderHash, address indexed owner, uint256 sellFilled, uint256 buyFilled);

    error Overfill(bytes32 orderHash);
    error NotPartiallyFillable(bytes32 orderHash);
    error LimitPrice(bytes32 orderHash);

    constructor(address _authority, Hub _hub, address _surplusRecipient) AccessManaged(_authority) {
        HUB = _hub;
        SURPLUS_RECIPIENT = _surplusRecipient;
    }

    /// TODO: Decide the EIP712 domain name and version. Currently "Transit Terminal" and "1".
    function _domainNameAndVersion() internal pure override returns (string memory name, string memory version) {
        return ("Transit Terminal", "1");
    }

    function DOMAIN_SEPARATOR() external view returns (bytes32) {
        return _domainSeparator();
    }

    function settle(Fill[] calldata fills) external restricted {
        for (uint256 i; i < fills.length; i++) {
            Fill calldata fill = fills[i];
            Order calldata order = fill.order;
            bytes32 orderHash = _hashOrder(order);

            uint256 filled = filledAmount[orderHash] + fill.sellFilled;
            if (filled > order.sellAmount) revert Overfill(orderHash);
            if (!order.partiallyFillable && fill.sellFilled != order.sellAmount) {
                revert NotPartiallyFillable(orderHash);
            }
            /// TODO: Decide overflow handling. These products revert for amounts above ~2^128; fullMulDiv avoids it.
            if (fill.buyFilled * order.sellAmount < fill.sellFilled * order.buyAmount) revert LimitPrice(orderHash);
            filledAmount[orderHash] = filled;

            address owner = _recoverOrderOwner(orderHash, fill.signature);
            HUB.move(owner, address(this), order.sellTokenChainId, order.sellToken, fill.sellFilled);

            emit Filled(orderHash, owner, fill.sellFilled, fill.buyFilled);
        }

        for (uint256 i; i < fills.length; i++) {
            Fill calldata fill = fills[i];
            HUB.move(
                address(this), fill.order.receiver, fill.order.buyTokenChainId, fill.order.buyToken, fill.buyFilled
            );
        }

        for (uint256 i; i < fills.length; i++) {
            Order calldata order = fills[i].order;
            uint256 surplus = HUB.balanceOf(address(this), order.sellTokenChainId, order.sellToken);
            if (surplus > 0) {
                HUB.move(address(this), SURPLUS_RECIPIENT, order.sellTokenChainId, order.sellToken, surplus);
            }
        }
    }

    function _hashOrder(Order calldata order) internal view returns (bytes32) {
        return _hashTypedData(
            keccak256(
                abi.encode(
                    ORDER_TYPEHASH,
                    order.sellTokenChainId,
                    order.sellToken,
                    order.buyTokenChainId,
                    order.buyToken,
                    order.sellAmount,
                    order.buyAmount,
                    order.receiver,
                    order.salt,
                    order.partiallyFillable
                )
            )
        );
    }

    function _recoverOrderOwner(bytes32 orderHash, bytes calldata signature) internal view returns (address) {
        return ECDSA.recoverCalldata(orderHash, signature);
    }

}
