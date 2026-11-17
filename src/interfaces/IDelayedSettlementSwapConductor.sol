// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.37;

import { ISwapConductor } from "src/interfaces/ISwapConductor.sol";

/// @title Transit Terminal DelayedSettlementSwapConductor
/// @notice Order types and entrypoints for swaps where one side may settle its payment after a delay, backed by
/// collateral.
interface IDelayedSettlementSwapConductor is ISwapConductor {

    /// @notice A user's signed order.
    /// @param ownerChainId Owner's account chainId.
    /// @param owner Owner's account address.
    /// @param sellTokenChainId Chain of the token sold.
    /// @param sellToken Address of the token sold.
    /// @param buyTokenChainId Chain of the token bought.
    /// @param buyToken Address of the token bought.
    /// @param sellAmount Maximum amount of sell token to sell across all fills.
    /// @param buyAmount Minimum buy token for the full sellAmount; sets the limit price.
    /// @param receiverChainId Receiver's account chainId.
    /// @param receiver Receiver's account address.
    /// @param expiresAt Timestamp; the order cannot be filled in an epoch that started at or after it.
    /// @param partiallyFillable Whether the order may be filled in parts.
    /// @param collateralized Whether the owner posts only amount / FILL_RATIO as collateral now and pays the rest
    /// within settlementPeriod. False means the full amount is escrowed at fill.
    /// @param settlementPeriod Time the owner of a collateralized order has to pay the rest, at most
    /// MAX_SETTLEMENT_PERIOD.
    /// @param salt User-set salt to disambiguate otherwise identical orders.
    struct DelayedSettlementOrder {
        uint64 ownerChainId;
        address owner;
        uint64 sellTokenChainId;
        address sellToken;
        uint64 buyTokenChainId;
        address buyToken;
        uint256 sellAmount;
        uint256 buyAmount;
        uint64 receiverChainId;
        address receiver;
        uint256 expiresAt;
        bool partiallyFillable;
        bool collateralized;
        uint256 settlementPeriod;
        bytes32 salt;
    }

    /// @notice Settlement bot provided fill data. Fills are per pair of orders matched. A single order that is filling
    /// several others may have several PairedFills mentioning that order by orderIndex.
    /// @param orderIndexes Indexes of the two matched orders in the settle orders array.
    /// @param amounts Sell amount each side provides.
    /// @param fees Fee taken from each side's amount.
    struct PairedFill {
        uint256[2] orderIndexes;
        uint256[2] amounts;
        uint256[2] fees;
    }

    /// @notice An escrow leg, saved in pairs per escrowId. This is the onchain log of a delayed settlement's status.
    /// @param accountId Account providing this side.
    /// @param receiverAccountId Account receiving the counterparty's side.
    /// @param assetId Asset this side provides.
    /// @param amount Amount this side provides.
    /// @param owed Amount still to be repaid; 0 once paid or for a non-delayed side.
    /// @param collateral Collateral posted for a delayed side.
    /// @param fee Fee taken from this side.
    struct Leg {
        bytes28 accountId;
        bytes28 receiverAccountId;
        bytes28 assetId;
        uint256 amount;
        uint256 owed;
        uint256 collateral;
        uint256 fee;
    }

    /// @notice An owner pre-approved an order on-chain.
    /// @param ownerAccountId Order owner.
    /// @param orderHash Order approved.
    /// @param order The approved order.
    event PreApproved(bytes28 indexed ownerAccountId, bytes32 indexed orderHash, DelayedSettlementOrder order);

    /// @notice A matched pair was placed in escrow.
    /// @param escrowId Escrow id.
    /// @param firstOrderHash First order of the pair.
    /// @param secondOrderHash Second order of the pair.
    event Escrowed(uint256 indexed escrowId, bytes32 indexed firstOrderHash, bytes32 indexed secondOrderHash);

    /// @notice One side of an escrow was repaid.
    /// @param escrowId Escrow id.
    /// @param side Side repaid (0 or 1).
    event Repaid(uint256 indexed escrowId, uint256 side);

    /// @notice Both sides were paid and the escrow released to the receivers.
    /// @param escrowId Escrow id.
    event Released(uint256 indexed escrowId);

    /// @notice An expired escrow was unwound.
    /// @param escrowId Escrow id.
    event Reclaimed(uint256 indexed escrowId);

    /// @notice A PairedFill is invalid.
    /// @param index Index of the fill.
    error BadPair(uint256 index);

    /// @notice The escrow's settlement period has ended.
    error SettlementPeriodOver();

    /// @notice The escrow's settlement period has not ended.
    error SettlementPeriodActive();

    /// @notice The leg has nothing left to repay.
    error NothingOwed();

    /// @notice Collateral divisor: a delayed side posts amount / FILL_RATIO.
    /// @return Fill ratio.
    function FILL_RATIO() external view returns (uint256);

    /// @notice Longest settlementPeriod an order may set.
    /// @return Maximum period in seconds.
    function MAX_SETTLEMENT_PERIOD() external view returns (uint256);

    /// @notice Account credited with forfeited collateral.
    /// @return Penalty recipient account id.
    function PENALTY_RECIPIENT_ACCOUNT_ID() external view returns (bytes28);

    /// @notice Number of escrows created; also the latest escrow id.
    /// @return Escrow count.
    function escrowCount() external view returns (uint256);

    /// @notice One leg of an escrow.
    /// @param escrowId Escrow id.
    /// @param side Side (0 or 1).
    /// @return accountId See Leg.
    /// @return receiverAccountId See Leg.
    /// @return assetId See Leg.
    /// @return amount See Leg.
    /// @return owed See Leg.
    /// @return collateral See Leg.
    /// @return fee See Leg.
    function escrowLegs(
        uint256 escrowId,
        uint256 side
    )
        external
        view
        returns (
            bytes28 accountId,
            bytes28 receiverAccountId,
            bytes28 assetId,
            uint256 amount,
            uint256 owed,
            uint256 collateral,
            uint256 fee
        );

    /// @notice Timestamp after which an escrow can no longer be repaid and may be reclaimed.
    /// @param escrowId Escrow id.
    /// @return Deadline timestamp.
    function escrowDeadline(uint256 escrowId) external view returns (uint256);

    /// @notice Approve one of the sender's orders on-chain so it can be settled without a signature.
    /// @param order Order to approve; the sender must be its owner.
    function preApprove(DelayedSettlementOrder calldata order) external;

    /// @notice Repay a leg of an escrow in full. Releases the escrow once both sides are paid.
    /// @param escrowId Escrow id.
    /// @param side Side to repay (0 or 1); the sender must own it.
    function repay(uint256 escrowId, uint256 side) external;

    /// @notice Unwind escrows whose settlement period ended without full repayment.
    /// @param escrowIds Escrows to reclaim.
    function reclaim(uint256[] calldata escrowIds) external;

    /// @notice Settle a batch of matched order pairs into escrow for the current epoch, then advance the epoch.
    /// @param epoch Epoch the batch was built for; must equal the Depot's current settlementEpoch.
    /// @param orders Orders referenced by the fills.
    /// @param signatures Owner signature per order, or empty if pre-approved.
    /// @param fills Matched pairs.
    function settle(
        uint256 epoch,
        DelayedSettlementOrder[] calldata orders,
        bytes[] calldata signatures,
        PairedFill[] calldata fills
    )
        external;

    /// @notice EIP-712 hash of an order, used as its id.
    /// @param order Order to hash.
    /// @return EIP-712 typed data hash.
    function hashOrder(DelayedSettlementOrder memory order) external view returns (bytes32);

}
