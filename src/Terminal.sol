// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.37;

import { EIP712 } from "solady/utils/EIP712.sol";
import { ECDSA } from "solady/utils/ECDSA.sol";
import { Hub } from "./warehouse/Hub.sol";

contract Terminal is EIP712 {

    /// TODO: Decide the remaining Order fields. validTo, feeAmount and partiallyFillable are the obvious candidates.
    struct Order {
        uint64 sellTokenChainId;
        address sellToken;
        uint64 buyTokenChainId;
        address buyToken;
        uint256 sellAmount;
        uint256 buyAmount;
        address receiver;
        bytes32 salt;
    }

    struct SignedOrder {
        Order order;
        bytes signature;
    }

    bytes32 public constant ORDER_TYPEHASH = keccak256(
        "Order(uint64 sellTokenChainId,address sellToken,uint64 buyTokenChainId,address buyToken,uint256 sellAmount,uint256 buyAmount,address receiver,bytes32 salt)"
    );

    Hub public immutable hub;

    mapping(bytes32 orderHash => bool) public filled;

    error OrderFilled(bytes32 orderHash);

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
    function settle(SignedOrder[] calldata orders) external {
        for (uint256 i; i < orders.length; i++) {
            Order calldata order = orders[i].order;
            bytes32 orderHash = _hashOrder(order);
            if (filled[orderHash]) revert OrderFilled(orderHash);
            filled[orderHash] = true;
            address owner = _recoverOrderOwner(orderHash, orders[i].signature);
            hub.move(owner, address(this), order.sellTokenChainId, order.sellToken, order.sellAmount);
        }

        for (uint256 i; i < orders.length; i++) {
            Order calldata order = orders[i].order;
            hub.move(address(this), order.receiver, order.buyTokenChainId, order.buyToken, order.buyAmount);
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
                    order.salt
                )
            )
        );
    }

    function _recoverOrderOwner(bytes32 orderHash, bytes calldata signature) internal view returns (address) {
        return ECDSA.recoverCalldata(orderHash, signature);
    }

}
