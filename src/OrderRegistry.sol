// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.37;

import { AccessManaged } from "@openzeppelin/contracts/access/manager/AccessManaged.sol";
import { EIP712 } from "solady/utils/EIP712.sol";
import { ECDSA } from "solady/utils/ECDSA.sol";
import { Hub } from "./Hub.sol";

/// TODO: Decide contract name. Currently OrderRegistry.
contract OrderRegistry is AccessManaged, EIP712 {

    struct Order {
        uint64 sellTokenChainId;
        address sellToken;
        uint64 buyTokenChainId;
        address buyToken;
        uint256 sellAmount;
        uint256 buyAmount;
        address receiver;
        uint256 expiresAt;
        bytes32 salt;
        bool partiallyFillable;
    }

    bytes32 public constant ORDER_TYPEHASH = keccak256(
        "Order(uint64 sellTokenChainId,address sellToken,uint64 buyTokenChainId,address buyToken,uint256 sellAmount,uint256 buyAmount,address receiver,uint256 expiresAt,bytes32 salt,bool partiallyFillable)"
    );

    Hub public immutable HUB;

    mapping(bytes32 orderHash => uint256) public filledAmount;
    mapping(address owner => mapping(bytes32 orderHash => uint256 epoch)) public cancelledFrom;
    mapping(address owner => mapping(bytes32 orderHash => bool)) public preApproved;

    event CancelRequested(address indexed owner, bytes32 indexed orderHash, uint256 effectiveAtEpoch);
    event PreApproved(address indexed owner, bytes32 indexed orderHash, Order order);

    error Expired(bytes32 orderHash);
    error Overfill(bytes32 orderHash);
    error NotPartiallyFillable(bytes32 orderHash);
    error Cancelled(bytes32 orderHash);
    error NotPreApproved(bytes32 orderHash);

    constructor(address _authority, Hub _hub) AccessManaged(_authority) {
        HUB = _hub;
    }

    /// TODO: Decide the EIP712 domain name and version. Currently "Transit Orders" and "1".
    function _domainNameAndVersion() internal pure override returns (string memory name, string memory version) {
        return ("Transit Orders", "1");
    }

    function DOMAIN_SEPARATOR() external view returns (bytes32) {
        return _domainSeparator();
    }

    function requestCancel(bytes32 orderHash) external {
        if (cancelledFrom[msg.sender][orderHash] != 0) return;
        uint256 effectiveAtEpoch = HUB.settlementEpoch() + 1;
        cancelledFrom[msg.sender][orderHash] = effectiveAtEpoch;
        emit CancelRequested(msg.sender, orderHash, effectiveAtEpoch);
    }

    function preApprove(Order calldata order) external {
        bytes32 orderHash = hashOrder(order);
        preApproved[msg.sender][orderHash] = true;
        emit PreApproved(msg.sender, orderHash, order);
    }

    function fill(
        Order calldata order,
        bytes calldata signature,
        uint256 sellFilled
    )
        external
        restricted
        returns (bytes32 orderHash, address owner)
    {
        orderHash = hashOrder(order);

        if (block.timestamp > order.expiresAt) revert Expired(orderHash);
        uint256 filled = filledAmount[orderHash] + sellFilled;
        if (filled > order.sellAmount) revert Overfill(orderHash);
        if (!order.partiallyFillable && sellFilled != order.sellAmount) revert NotPartiallyFillable(orderHash);
        filledAmount[orderHash] = filled;

        // 20-byte signature is the owner's address: pre-approved order. Otherwise ECDSA.
        if (signature.length == 20) {
            owner = address(bytes20(signature));
            if (!preApproved[owner][orderHash]) revert NotPreApproved(orderHash);
        } else {
            owner = ECDSA.recoverCalldata(orderHash, signature);
        }
        uint256 cancelled = cancelledFrom[owner][orderHash];
        if (cancelled != 0 && HUB.settlementEpoch() >= cancelled) revert Cancelled(orderHash);
    }

    function hashOrder(Order calldata order) public view returns (bytes32) {
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
                    order.expiresAt,
                    order.salt,
                    order.partiallyFillable
                )
            )
        );
    }

}
