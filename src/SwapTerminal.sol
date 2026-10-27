// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.37;

import { AccessManaged } from "@openzeppelin/contracts/access/manager/AccessManaged.sol";
import { ECDSA } from "solady/utils/ECDSA.sol";
import { EIP712 } from "solady/utils/EIP712.sol";
import { FixedPointMathLib } from "solady/utils/FixedPointMathLib.sol";
import { ReentrancyGuard } from "solady/utils/ReentrancyGuard.sol";
import { Hub } from "./Hub.sol";
import { TransitTokenLib } from "./helpers/TransitTokenLib.sol";
import { TurnstileGated } from "./TurnstileGated.sol";

contract SwapTerminal is AccessManaged, ReentrancyGuard, EIP712, TurnstileGated {

    struct Order {
        uint64 ownerChainId;
        address owner;
        bytes32 sellTokenId;
        bytes32 buyTokenId;
        uint256 sellAmount;
        uint256 buyAmount;
        uint64 receiverChainId;
        address receiver;
        uint256 expiresAt;
        bytes32 salt;
        bool partiallyFillable;
    }

    struct Fill {
        uint256 sellFilled;
        uint256 buyFilled;
    }

    /// TODO: Decide fields. The full Order would allow keying cancelledFrom by hash alone.
    struct OrderCancellationRequest {
        uint64 ownerChainId;
        address owner;
        bytes32 orderHash;
        bytes32 sellTokenId;
        uint256 maxFee;
    }

    struct Fee {
        bytes32 assetId;
        uint256 amount;
    }

    bytes32 public constant ORDER_TYPEHASH = keccak256(
        "Order(uint64 ownerChainId,address owner,bytes32 sellTokenId,bytes32 buyTokenId,uint256 sellAmount,uint256 buyAmount,uint64 receiverChainId,address receiver,uint256 expiresAt,bytes32 salt,bool partiallyFillable)"
    );

    bytes32 public constant ORDER_CANCELLATION_REQUEST_TYPEHASH = keccak256(
        "OrderCancellationRequest(uint64 ownerChainId,address owner,bytes32 orderHash,bytes32 sellTokenId,uint256 maxFee)"
    );

    Hub public immutable HUB;
    bytes32 public immutable SURPLUS_RECIPIENT_ACCOUNT_ID;

    mapping(bytes32 orderHash => uint256) public filledAmount;
    mapping(bytes32 accountId => mapping(bytes32 orderHash => uint256 epoch)) public cancelledFrom;
    mapping(bytes32 orderHash => bool) public preApproved;

    event OrderCancellationRequested(bytes32 indexed ownerAccountId, bytes32 indexed orderHash, uint256 effectiveAtEpoch);
    event PreApproved(bytes32 indexed ownerAccountId, bytes32 indexed orderHash);
    event Filled(bytes32 indexed orderHash, bytes32 indexed ownerAccountId, uint256 sellFilled, uint256 buyFilled);

    error LimitPrice(bytes32 orderHash);
    error BadSignature();
    error NotPreApproved(bytes32 orderHash);
    error LengthMismatch();
    error EmptyBatch();
    error NotOwner();
    error ExceedsMaxFee();
    error Expired(bytes32 id);
    error Overfill(bytes32 orderHash);
    error NotPartiallyFillable(bytes32 orderHash);
    error FlaggedAssetId();
    error Cancelled(bytes32 orderHash);
    error HubPaused();

    constructor(
        address _authority,
        Hub _hub,
        bytes32 _surplusRecipientAccountId,
        address _turnstile
    )
        AccessManaged(_authority)
        TurnstileGated(_turnstile)
    {
        HUB = _hub;
        SURPLUS_RECIPIENT_ACCOUNT_ID = _surplusRecipientAccountId;
    }

    /// TODO: Decide the EIP712 domain name and version. Currently "Transit Hub" and "1". verifyingContract is now SwapTerminal, so a terminal swap invalidates open signed orders (KDD #13).
    function _domainNameAndVersion() internal pure override returns (string memory, string memory) {
        return ("Transit Hub", "1");
    }

    function DOMAIN_SEPARATOR() external view returns (bytes32) {
        return _domainSeparator();
    }

    // ========================================= USER =========================================

    function requestOrderCancellation(OrderCancellationRequest calldata request) external {
        bytes32 accountId = _senderAccountId();
        if (accountId != TransitTokenLib.formatAccountId(request.ownerChainId, request.owner)) revert NotOwner();
        _requireHubNotPaused();
        if (cancelledFrom[accountId][request.orderHash] != 0) return;
        uint256 effectiveAtEpoch = HUB.settlementEpoch() + 1;
        cancelledFrom[accountId][request.orderHash] = effectiveAtEpoch;
        emit OrderCancellationRequested(accountId, request.orderHash, effectiveAtEpoch);
    }

    /// TODO: Decide whether PreApproved should carry the full Order again.
    function preApprove(Order calldata order) external {
        bytes32 accountId = _senderAccountId();
        if (accountId != TransitTokenLib.formatAccountId(order.ownerChainId, order.owner)) revert NotOwner();
        _requireHubNotPaused();
        bytes32 orderHash = hashOrder(order);
        preApproved[orderHash] = true;
        emit PreApproved(accountId, orderHash);
    }

    // ========================================= SOLVER =========================================

    function facilitateOrderCancellation(
        OrderCancellationRequest[] calldata requests,
        bytes[] calldata signatures,
        uint256[] calldata fees
    )
        external
        restricted
        nonReentrant
    {
        _requireHubNotPaused();
        if (requests.length == 0) revert EmptyBatch();
        if (requests.length != signatures.length || requests.length != fees.length) revert LengthMismatch();
        uint256 settlementEpoch = HUB.settlementEpoch();

        for (uint256 i; i < requests.length; i++) {
            OrderCancellationRequest calldata request = requests[i];
            if (TransitTokenLib.hasFlags(request.sellTokenId)) revert FlaggedAssetId();
            bytes32 ownerAccountId = TransitTokenLib.formatAccountId(request.ownerChainId, request.owner);

            if (ECDSA.recoverCalldata(hashOrderCancellationRequest(request), signatures[i]) != request.owner) {
                revert BadSignature();
            }
            uint256 cancelled = cancelledFrom[ownerAccountId][request.orderHash];
            if (cancelled != 0 && cancelled <= settlementEpoch) continue;
            if (fees[i] > request.maxFee) revert ExceedsMaxFee();

            cancelledFrom[ownerAccountId][request.orderHash] = settlementEpoch;

            /// TODO: Decide fee recipient. Currently msg.sender.
            if (fees[i] != 0) {
                HUB.transferFrom(
                    ownerAccountId,
                    TransitTokenLib.formatAccountId(uint64(block.chainid), msg.sender),
                    request.sellTokenId,
                    fees[i]
                );
            }

            emit OrderCancellationRequested(ownerAccountId, request.orderHash, settlementEpoch);
        }
    }

    function settle(
        uint256 epoch,
        Order[] calldata orders,
        bytes[] calldata signatures,
        Fill[] calldata fills,
        Fee[] calldata fees
    )
        external
        restricted
    {
        Hub.TransferDelta[] memory deltas = new Hub.TransferDelta[](orders.length * 2 + fees.length);
        if (orders.length != 0) {
            if (orders.length != signatures.length || orders.length != fills.length) revert LengthMismatch();
            (bytes32[] memory ownerAccountIds, bytes32[] memory orderHashes) = _checkOrders(orders, signatures, fills);
            _fillOrders(orders, fills, ownerAccountIds, orderHashes, deltas);
        }

        for (uint256 i; i < fees.length; i++) {
            Fee calldata fee = fees[i];
            deltas[orders.length * 2 + i] =
                Hub.TransferDelta(bytes32(0), SURPLUS_RECIPIENT_ACCOUNT_ID, fee.assetId, fee.amount);
        }

        HUB.transferAmong(deltas);

        HUB.advanceEpoch(epoch);
    }

    function _checkOrders(
        Order[] calldata orders,
        bytes[] calldata signatures,
        Fill[] calldata fills
    )
        internal
        view
        returns (bytes32[] memory ownerAccountIds, bytes32[] memory orderHashes)
    {
        ownerAccountIds = new bytes32[](orders.length);
        orderHashes = new bytes32[](orders.length);
        for (uint256 i; i < orders.length; i++) {
            Order calldata order = orders[i];
            bytes32 orderHash = hashOrder(order);
            orderHashes[i] = orderHash;
            ownerAccountIds[i] = TransitTokenLib.formatAccountId(order.ownerChainId, order.owner);

            if (block.timestamp > order.expiresAt) revert Expired(orderHash);
            if (!order.partiallyFillable && fills[i].sellFilled != order.sellAmount) {
                revert NotPartiallyFillable(orderHash);
            }

            // Empty signature: pre-approved order. Otherwise ECDSA.
            if (signatures[i].length == 0) {
                if (!preApproved[orderHash]) revert NotPreApproved(orderHash);
            } else if (ECDSA.recoverCalldata(orderHash, signatures[i]) != order.owner) {
                revert BadSignature();
            }
        }
    }

    function _fillOrders(
        Order[] calldata orders,
        Fill[] calldata fills,
        bytes32[] memory ownerAccountIds,
        bytes32[] memory orderHashes,
        Hub.TransferDelta[] memory deltas
    )
        internal
    {
        uint256 settlementEpoch = HUB.settlementEpoch();
        for (uint256 i; i < orders.length; i++) {
            Order calldata order = orders[i];
            uint256 filled = filledAmount[orderHashes[i]] + fills[i].sellFilled;
            if (filled > order.sellAmount) revert Overfill(orderHashes[i]);
            filledAmount[orderHashes[i]] = filled;
            uint256 cancelled = cancelledFrom[ownerAccountIds[i]][orderHashes[i]];
            if (cancelled != 0 && settlementEpoch >= cancelled) revert Cancelled(orderHashes[i]);

            if (
                fills[i].buyFilled
                    < FixedPointMathLib.fullMulDivUp(fills[i].sellFilled, order.buyAmount, order.sellAmount)
            ) {
                revert LimitPrice(orderHashes[i]);
            }
            deltas[i] = Hub.TransferDelta(ownerAccountIds[i], bytes32(0), order.sellTokenId, fills[i].sellFilled);
            deltas[orders.length + i] = Hub.TransferDelta(
                bytes32(0),
                TransitTokenLib.formatAccountId(order.receiverChainId, order.receiver),
                order.buyTokenId,
                fills[i].buyFilled
            );

            emit Filled(orderHashes[i], ownerAccountIds[i], fills[i].sellFilled, fills[i].buyFilled);
        }
    }

    function _requireHubNotPaused() internal view {
        if (HUB.paused()) revert HubPaused();
    }

    // ========================================= VIEWS =========================================

    function hashOrder(Order memory order) public view returns (bytes32) {
        return _hashTypedData(
            keccak256(
                abi.encode(
                    ORDER_TYPEHASH,
                    order.ownerChainId,
                    order.owner,
                    order.sellTokenId,
                    order.buyTokenId,
                    order.sellAmount,
                    order.buyAmount,
                    order.receiverChainId,
                    order.receiver,
                    order.expiresAt,
                    order.salt,
                    order.partiallyFillable
                )
            )
        );
    }

    function hashOrderCancellationRequest(OrderCancellationRequest memory request) public view returns (bytes32) {
        return _hashTypedData(
            keccak256(
                abi.encode(
                    ORDER_CANCELLATION_REQUEST_TYPEHASH,
                    request.ownerChainId,
                    request.owner,
                    request.orderHash,
                    request.sellTokenId,
                    request.maxFee
                )
            )
        );
    }

}
