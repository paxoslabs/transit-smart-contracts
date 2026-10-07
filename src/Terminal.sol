// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.37;

import { EIP712 } from "solady/utils/EIP712.sol";
import { ECDSA } from "solady/utils/ECDSA.sol";
import { Hub } from "./warehouse/Hub.sol";

contract Terminal is EIP712 {

    /// TODO: Decide the remaining Order fields. validTo and feeAmount are the obvious candidates.
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

    Hub public immutable hub;

    mapping(bytes32 orderHash => uint256) public filledAmount;

    event Filled(bytes32 indexed orderHash, address indexed owner, uint256 sellFilled, uint256 buyFilled);

    error Overfill(bytes32 orderHash);
    error NotPartiallyFillable(bytes32 orderHash);
    error LimitPrice(bytes32 orderHash);

    constructor(Hub _hub) {
        hub = _hub;
    }

    /// TODO: Decide the EIP712 domain name and version. Currently "Transit Terminal" and "1".
    function _domainNameAndVersion() internal pure override returns (string memory name, string memory version) {
        return ("Transit Terminal", "1");
    }

    function DOMAIN_SEPARATOR() external view returns (bytes32) {
        return _domainSeparator();
    }

    /// TODO: Decide what happens to trade surplus. Since this is not UCP, a batch can over-collateralize and
    /// the excess stays in this contract with nothing to claim it. Leaving it here for now.
    /// TODO: Decide solver access control. settle is unguarded, so anyone can call it.
    function settle(Fill[] calldata fills) external {
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
            hub.move(owner, address(this), order.sellTokenChainId, order.sellToken, fill.sellFilled);

            emit Filled(orderHash, owner, fill.sellFilled, fill.buyFilled);
        }

        for (uint256 i; i < fills.length; i++) {
            Fill calldata fill = fills[i];
            hub.move(
                address(this), fill.order.receiver, fill.order.buyTokenChainId, fill.order.buyToken, fill.buyFilled
            );
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
