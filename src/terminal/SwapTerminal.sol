// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.37;

import { AccessManaged } from "@openzeppelin/contracts/access/manager/AccessManaged.sol";
import { ECDSA } from "solady/utils/ECDSA.sol";
import { EIP712 } from "solady/utils/EIP712.sol";
import { ReentrancyGuard } from "solady/utils/ReentrancyGuard.sol";
import { Depot } from "../Depot.sol";
import { TransitTokenLib } from "../helpers/TransitTokenLib.sol";
import { TurnstileGated } from "../TurnstileGated.sol";

abstract contract SwapTerminal is AccessManaged, ReentrancyGuard, EIP712, TurnstileGated {

    /// TODO: Decide fields. The full Order would allow keying cancelledFrom by hash alone.
    struct OrderCancellationRequest {
        uint64 ownerChainId;
        address owner;
        bytes32 orderHash;
        bytes32 sellTokenId;
        uint256 maxFee;
    }

    bytes32 public constant ORDER_CANCELLATION_REQUEST_TYPEHASH = keccak256(
        "OrderCancellationRequest(uint64 ownerChainId,address owner,bytes32 orderHash,bytes32 sellTokenId,uint256 maxFee)"
    );

    Depot public immutable DEPOT;
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
    error Cancelled(bytes32 orderHash);

    constructor(
        address _authority,
        Depot _depot,
        bytes32 _surplusRecipientAccountId,
        address _turnstile
    )
        AccessManaged(_authority)
        TurnstileGated(_turnstile)
    {
        DEPOT = _depot;
        SURPLUS_RECIPIENT_ACCOUNT_ID = _surplusRecipientAccountId;
    }

    function DOMAIN_SEPARATOR() external view returns (bytes32) {
        return _domainSeparator();
    }

    // ========================================= USER =========================================

    function requestOrderCancellation(OrderCancellationRequest calldata request) external {
        bytes32 accountId = _senderAccountId();
        if (accountId != TransitTokenLib.formatAccountId(request.ownerChainId, request.owner)) revert NotOwner();
        if (cancelledFrom[accountId][request.orderHash] != 0) return;
        uint256 effectiveAtEpoch = DEPOT.settlementEpoch() + 1;
        cancelledFrom[accountId][request.orderHash] = effectiveAtEpoch;
        emit OrderCancellationRequested(accountId, request.orderHash, effectiveAtEpoch);
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
        if (requests.length == 0) revert EmptyBatch();
        if (requests.length != signatures.length || requests.length != fees.length) revert LengthMismatch();
        uint256 settlementEpoch = DEPOT.settlementEpoch();

        for (uint256 i; i < requests.length; i++) {
            OrderCancellationRequest calldata request = requests[i];
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
                DEPOT.transferFrom(
                    ownerAccountId,
                    TransitTokenLib.formatAccountId(uint64(block.chainid), msg.sender),
                    request.sellTokenId,
                    fees[i]
                );
            }

            emit OrderCancellationRequested(ownerAccountId, request.orderHash, settlementEpoch);
        }
    }

    // ========================================= VIEWS =========================================

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
