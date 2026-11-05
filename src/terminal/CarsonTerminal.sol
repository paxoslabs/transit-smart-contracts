// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.37;

import { AccessManaged } from "@openzeppelin/contracts/access/manager/AccessManaged.sol";
import { EIP712 } from "solady/utils/EIP712.sol";
import { IDepot } from "../depot/IDepot.sol";
import { TurnstileGated } from "../TurnstileGated.sol";

/**
 * @title CarsonTerminal
 * Demonstrates a new Terminal design based on "rule modules"
 * Really the idea is to have a main terminal (this contract) where settle is called in a single entrypoint.
 * Sub terminals (rule modules) govern special settlement rules like delayed settlement. This contract contains the
 * default (spot settlement).
 *
 * I also included some general improvements as I see them such as:
 * - Simplified settle() input
 * - Order validation in-loop (rather than in 2 loops)
 */
contract CarsonTerminal is AccessManaged, EIP712, TurnstileGated {

    address public immutable DEPOT;
    bytes32 public immutable SURPLUS_RECIPIENT_ACCOUNT_ID;

    mapping(bytes32 orderHash => uint256) public filledAmount;
    mapping(bytes32 accountId => mapping(bytes32 orderHash => uint256 epoch)) public cancelledFrom;
    mapping(bytes32 orderHash => bool) public preApproved;

    event OrderCancellationRequested(
        bytes32 indexed ownerAccountId, bytes32 indexed orderHash, uint256 effectiveAtEpoch
    );
    event PreApproved(bytes32 indexed ownerAccountId, bytes32 indexed orderHash);
    event Filled(bytes32 indexed orderHash, bytes32 indexed ownerAccountId, uint256 sellFilled, uint256 buyFilled);

    error LimitPrice(bytes32 orderHash);
    error BadSignature();
    error NotPreApproved(bytes32 orderHash);
    error LengthMismatch();
    error NotOwner();
    error Expired(bytes32 id);
    error Overfill(bytes32 orderHash);
    error NotPartiallyFillable(bytes32 orderHash);
    error Cancelled(bytes32 orderHash);

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

        // used for rules custom logic
        bytes extraData;
    }

    struct Fill {
        uint256 sellTokenTaken;
        uint256 buyTokenGiven;
    }

    struct OrderFillPair {
        Order order;
        bytes orderSignature;
        Fill fill;
    }

    // Rules are really a direction to consult a "rule module" or sub terminal on settlement logic defined in the call.
    struct Rule {
        address targetModule;
        bytes ruleCall;
    }

    struct Fee {
        bytes32 assetId;
        uint256 amount;
    }

    struct OrderBatch {
        OrderFillPair[] orderFillPairs;
        Rule rule;
    }

    bytes32 public constant ORDER_TYPEHASH = keccak256(
        "Order(uint64 ownerChainId,address owner,bytes32 sellTokenId,bytes32 buyTokenId,uint256 sellAmount,uint256 buyAmount,uint64 receiverChainId,address receiver,uint256 expiresAt,bytes32 salt,bool partiallyFillable)"
    );

    constructor(
        address _authority,
        address _depot,
        bytes32 _surplusRecipientAccountId,
        address _turnstile
    )
        AccessManaged(_authority)
        TurnstileGated(_turnstile)
    {
        DEPOT = _depot;
        SURPLUS_RECIPIENT_ACCOUNT_ID = _surplusRecipientAccountId;
        TURNSTILE = _turnstile;
    }

    function DOMAIN_SEPARATOR() external view returns (bytes32) {
        return _domainSeparator();
    }

    function _domainNameAndVersion() internal pure override returns (string memory, string memory) {
        return ("Transit SpotSwapTerminal", "1");
    }

    function preApprove(Order calldata order) external {
        bytes32 accountId = _senderAccountId();
        if (accountId != TransitTokenLib.formatAccountId(order.ownerChainId, order.owner)) revert NotOwner();
        bytes32 orderHash = hashOrder(order);
        preApproved[orderHash] = true;
        emit PreApproved(accountId, orderHash);
    }

    function settle(OrderBatch[] orderBatches, Fee[] fees, uint256 deltasLength) external restricted {
        // NOTE: optimistically let solver provide length of deltas array, it will error if provided too small and only
        // waste gas if too large. Can possible check no empty elements later as well
        uint256 deltaCounter;
        IDepot.TransferDelta[] memory deltas = new IDepot.TransferDelta[](deltasLength);

        // checks on batch
        require(orderBatches.length != 0);

        // loop batches
        for (uint256 orderBatchIndex; orderBatchIndex < orderBatches; ++i) {
            OrderBatch memory orderBatch = orderBatches[orderBatchIndex];

            // if batch target == this then execute default. Otherwise execute rule
            if (orderbatch.rule.targetModule == address(this)) {
                deltaCounter = _executeDefaultRuleSpotSwap(orderBatch, deltas);
            } else {
                (bytes response, bool success) =
                    orderbatch.rule.targetModule.call(abi.encodePacked(orderbatch.rule.ruleCall, deltas, orderbatch));
                require(success);
                deltaCounter = abi.decode(response, (uint256));
            }
        }

        // Loop and process fees
        for (uint256 i; i < fees.length; i++) {
            Fee calldata fee = fees[i];
            deltas[deltaCounter++] =
                IDepot.TransferDelta(bytes32(0), SURPLUS_RECIPIENT_ACCOUNT_ID, fee.assetId, fee.amount);
        }

        // IDEA: I think there's room to make a kind of deltas library or something here. Or just batch the deltas and
        // their counter in an object. But a library would be nice where .push can be used to ensure there's never
        // accidental overwriting or something. I bet Claude would make this easily and accurately

        IDepot(DEPOT).transferAmong(deltas);

        IDepot(DEPOT).advanceEpoch(epoch);
    }

    // The default execution of an order – spot swap. Implemented here to save gas on no external calls as this will
    // be most orders. Works nearly the same as in SpotSwapTerminal but does just 1 loop
    function _executeDefaultRuleSpotSwap(
        OrderBatch orderBatch,
        IDepot.TransferDelta[] deltas,
        uint256 deltaCounter
    )
        internal
        returns (deltaCounter)
    {
        uint256 settlementEpoch = IDepot(DEPOT).settlementEpoch();

        for (uint256; i < orderBatch.orderFillPairs.length; ++i) {
            OrderFillPair orderFillPair = orderBatch[i].orderFillPair;
            (bytes32 orderHash, bytes32 ownerAccountId) = checkValidOrder(orderFillPair);

            // Check filled amount
            uint256 filled = filledAmount[orderHash] + orderFillPair.fill.sellTokenTaken; // sell token is what's
            // "filled"
            if (filled > orderFillPair.order.sellAmount) revert Overfill(orderHash);
            filledAmount[orderHash] = filled;

            // Check cancelled
            uint256 cancelled = cancelledFrom[ownerAccountId][orderHash];
            if (cancelled != 0 && settlementEpoch >= cancelled) revert Cancelled(orderHash);

            // Check Limit price
            if (
                orderFillPair.fill.buyTokenGiven
                    < FixedPointMathLib.fullMulDivUp(
                        orderFillPair.fill.sellTokenTaken, orderFillPair.order.buyAmount, orderFillPair.order.sellAmount
                    )
            ) {
                revert LimitPrice(orderHash);
            }

            // Create Deltas
            deltas[delatCounter++] = IDepot.TransferDelta(
                ownerAccountId, bytes32(0), orderFillPair.order.sellTokenId, orderFillPair.fill.sellTokenTaken
            );
            deltas[delatCounter++] = IDepot.TransferDelta(
                bytes32(0),
                TransitTokenLib.formatAccountId(orderFillPair.order.receiverChainId, orderFillPair.order.receiver),
                orderFillPair.order.buyTokenId,
                orderFillPair.fill.buyTokenGiven
            );

            // emit Filled event
            emit Filled(orderHash, ownerAccountId, orderFillPair.fill.sellTokenTaken, orderFillPair.fill.buyTokenGiven);
        }
    }

    // Valid order check. I made this public to be able to call in the rule modules if the validation scheme can be
    // re-used
    function checkValidOrder(OrderFillPair orderFillPair) public returns (bytes32 orderHash, bytes32 ownerAccountId) {
        Order order = orderFillPair.order;
        bytes32 orderHash = orderBatches[orderBatchIndex];
        bytes32 ownerAccountId =
            TransitTokenLib.formatAccountId(orderFillPair.order.ownerChainId, orderFillPair.order.owner);

        // Check expiry and patial fill setting
        if (block.timestamp > order.expiresAt) revert Expired(orderHash);
        if (!order.partiallyFillable && orderFillPair.sellFilled != order.sellAmount) {
            revert NotPartiallyFillable(orderHash);
        }

        // Empty signature: pre-approved order. Otherwise ECDSA.
        if (orderFillpair.signature.length == 0) {
            if (!preApproved[orderHash]) revert NotPreApproved(orderHash);
        } else if (ECDSA.recoverCalldata(orderHash, orderFillpair.signature) != order.owner) {
            revert BadSignature();
        }
    }

    function hashOrder(Order memory order) public pure returns (bytes32) {
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

}

// The following is pseudocode, I didn't want to spend too much time here, but it hopefully demonstrates the idea
contract DelayedSettlementRuleModule {

    CarsonTerminal terminal;
    uint256 constant COLLATERAL_RATIO = 100;

    bytes32 immutable ESCROW_ACCOUNT_ID;

    mapping(bytes32 => OrderFillPair) public ordersInEscrow;

    constructor() {
        ESCROW_ACCOUNT_ID = TransitTokenLib.formatAccountId(uint64(block.chainid), address(this));
    }

    // NOTE: The biggest issue here is that we must entrust the rule modules to perform the checkValidOrder, it's not
    // shared in the parent. But upon thinking about it, this isn't any new trust assumption. Either way, these modules
    // need Terminal privledges to call reserve or transfer or what have you. So either way they have full ability to
    // rug funds and can be thought of as the same trust layer as just creating a second terminal. This model only
    // unlocks single call settlement, not a better trust model
    function escrow(
        IDepot.TransferDelta[] deltas,
        uint256 deltaCounter,
        OrderBatch orderBatch
    )
        external
        onlyTerminal
        returns (uint256 deltaCounter)
    {
        for (uint256 i; i < orderBatch.orderFillPairs.length; ++i) {
            OrderFillPair o = orderBatch.orderFillpairs[i];

            (bytes32 orderHash, bytes32 ownerAccountId) = terminal.checkValidOrder(orderFillPair);

            uint256 amount = o.fill.sellTokenTaken;

            // extra data encodes a boolean to signify if this order is collateralized or not (makers will be
            // collateralizing while buyers will not)
            if (abi.decode(order.extraData, bool) == true) {
                deltas[deltaCounter++] = IDepot.TransferDelta(
                    ownerAccountId, ESCROW_ACCOUNT_ID, o.order.sellTokenId, amount * COLLATERAL_RATIO / 10_000
                );
            } else {
                deltas[deltaCounter++] =
                    IDepot.TransferDelta(ownerAccountId, ESCROW_ACCOUNT_ID, o.order.sellTokenId, amount);
            }

            ordersInEscrow[orderHash] = o;
        }
    }

}
