// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.37;

import { ISwapConductor } from "src/interfaces/ISwapConductor.sol";

/// @title Transit Terminal SpotSwapConductor
/// @notice Order types and solver entrypoint for spot swaps settled in the Depot.
interface ISpotSwapConductor is ISwapConductor {

    /// @notice A user's signed swap order.
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
    /// @param partiallyFillable Whether the order may be filled in parts; otherwise it must fill sellAmount at once.
    /// @param salt User-set salt to disambiguate otherwise identical orders.
    struct Order {
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
        bytes32 salt;
    }

    /// @notice Amounts a solver fills an order with.
    /// @param sellFilled Amount of sell token taken from the owner.
    /// @param buyFilled Amount of buy token given to the receiver.
    struct Fill {
        uint256 sellFilled;
        uint256 buyFilled;
    }

    /// @notice An order with its authorization and the fill to apply.
    /// @param order The order.
    /// @param signature Owner's EIP-712 signature, or empty if the order was pre-approved.
    /// @param fill Amounts to fill.
    struct OrderFill {
        Order order;
        bytes signature;
        Fill fill;
    }

    /// @notice A fee minted to SURPLUS_RECIPIENT_ACCOUNT_ID.
    /// @param assetId Asset of the fee.
    /// @param amount Fee amount.
    struct Fee {
        bytes28 assetId;
        uint256 amount;
    }

    /// @notice An owner pre-approved an order on-chain.
    /// @param ownerAccountId Order owner.
    /// @param orderHash Order approved.
    /// @param order The approved order.
    event PreApproved(bytes28 indexed ownerAccountId, bytes32 indexed orderHash, Order order);

    /// @notice Approve one of the sender's orders on-chain so it can be settled without a signature.
    /// @param order Order to approve; the sender must be its owner.
    function preApprove(Order calldata order) external;

    /// @notice Settle a batch of order fills and fees for the current epoch, then advance the epoch.
    /// @dev Reverts BadEpoch if the epoch advanced since the solver built the batch.
    /// @param epoch Epoch the batch was built for; must equal the Depot's current settlementEpoch.
    /// @param orderFills Orders, signatures and fill amounts.
    /// @param fees Fees minted to SURPLUS_RECIPIENT_ACCOUNT_ID.
    function settle(uint256 epoch, OrderFill[] calldata orderFills, Fee[] calldata fees) external;

    /// @notice EIP-712 hash of an order, used as its id.
    /// @param order Order to hash.
    /// @return EIP-712 typed data hash.
    function hashOrder(Order calldata order) external view returns (bytes32);

}
