// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.37;

import { ERC20 } from "solady/tokens/ERC20.sol";
import { EIP712 } from "solady/utils/EIP712.sol";
import { ECDSA } from "solady/utils/ECDSA.sol";
import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";

contract Terminal is EIP712 {

    /// TODO: Decide the remaining Order fields. As written there is no nonce or deadline, so a signed order
    /// replays and can be filled again in a later batch against the owner's standing approval. validTo,
    /// feeAmount and partiallyFillable are the other obvious candidates.
    struct Order {
        ERC20 sellToken;
        ERC20 buyToken;
        uint256 sellAmount;
        uint256 buyAmount;
        address receiver;
    }

    struct SignedOrder {
        Order order;
        bytes signature;
    }

    bytes32 public constant ORDER_TYPEHASH =
        keccak256("Order(address sellToken,address buyToken,uint256 sellAmount,uint256 buyAmount,address receiver)");

    /// TODO: Decide the EIP712 domain name and version. I used "Transit Terminal" and "1".
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
            SafeTransferLib.safeTransferFrom(address(order.sellToken), owner, address(this), order.sellAmount);
        }

        for (uint256 i; i < orders.length; i++) {
            Order calldata order = orders[i].order;
            SafeTransferLib.safeTransfer(address(order.buyToken), order.receiver, order.buyAmount);
        }
    }

    function _recoverOrderOwner(SignedOrder calldata signed) internal view returns (address) {
        bytes32 structHash = keccak256(
            abi.encode(
                ORDER_TYPEHASH,
                signed.order.sellToken,
                signed.order.buyToken,
                signed.order.sellAmount,
                signed.order.buyAmount,
                signed.order.receiver
            )
        );
        return ECDSA.recoverCalldata(_hashTypedData(structHash), signed.signature);
    }

}
