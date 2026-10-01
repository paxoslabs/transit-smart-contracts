// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.37;

import { EIP712 } from "solady/utils/EIP712.sol";
import { ECDSA } from "solady/utils/ECDSA.sol";
import { WarehouseHub } from "./warehouse/WarehouseHub.sol";

contract Terminal is EIP712 {

    /// TODO: Decide the remaining Order fields. As written there is no nonce or deadline, so a signed order
    /// replays and can be filled again in a later batch against the owner's hub balance. validTo,
    /// feeAmount and partiallyFillable are the other obvious candidates.
    struct Order {
        uint64 sellTokenChainId;
        address sellToken;
        uint64 buyTokenChainId;
        address buyToken;
        uint256 sellAmount;
        uint256 buyAmount;
        address receiver;
    }

    struct SignedOrder {
        Order order;
        bytes signature;
    }

    bytes32 public constant ORDER_TYPEHASH = keccak256(
        "Order(uint64 sellTokenChainId,address sellToken,uint64 buyTokenChainId,address buyToken,uint256 sellAmount,uint256 buyAmount,address receiver)"
    );

    WarehouseHub public immutable hub;

    constructor(WarehouseHub _hub) {
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
            address owner = _recoverOrderOwner(orders[i]);
            hub.move(owner, address(this), order.sellTokenChainId, order.sellToken, order.sellAmount);
        }

        for (uint256 i; i < orders.length; i++) {
            Order calldata order = orders[i].order;
            hub.move(address(this), order.receiver, order.buyTokenChainId, order.buyToken, order.buyAmount);
        }
    }

    function _recoverOrderOwner(SignedOrder calldata signed) internal view returns (address) {
        bytes32 structHash = keccak256(
            abi.encode(
                ORDER_TYPEHASH,
                signed.order.sellTokenChainId,
                signed.order.sellToken,
                signed.order.buyTokenChainId,
                signed.order.buyToken,
                signed.order.sellAmount,
                signed.order.buyAmount,
                signed.order.receiver
            )
        );
        return ECDSA.recoverCalldata(_hashTypedData(structHash), signed.signature);
    }

}
