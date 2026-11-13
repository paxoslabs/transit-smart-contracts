// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.37;

library Typehashes {

    /// @dev EIP-712 type hash for the Deposit action.
    bytes32 internal constant DEPOSIT_ACTION = keccak256(
        "DepositAction(address asset,uint256 amount,uint64 toChainId,address to,uint256 deadline,bytes32 salt,Permit permit)Permit(uint256 deadline,uint8 v,bytes32 r,bytes32 s)"
    );
    /// @dev EIP-712 type hash for the Permit struct nested within the Deposit action.
    bytes32 internal constant PERMIT = keccak256("Permit(uint256 deadline,uint8 v,bytes32 r,bytes32 s)");
    /// @dev EIP-712 type hash for the Withdrawal action.
    bytes32 internal constant WITHDRAWAL_ACTION = keccak256(
        "WithdrawalAction(uint64 ownerChainId,address owner,address to,bytes32 assetId,uint256 amount,uint256 deadline,bool partiallyFillable,bytes32 salt)"
    );
    /// @dev EIP-712 type hash for a Generic action.
    bytes32 internal constant GENERIC_ACTION =
        keccak256("GenericAction(address target,bytes data,uint256 deadline,bytes32 salt)");
    /// @dev EIP-712 type hash for a UserConductor transfer request.
    bytes32 internal constant TRANSFER_REQUEST = keccak256(
        "TransferRequest(uint64 ownerChainId,address owner,uint64 toChainId,address to,bytes32 assetId,uint256 amount,uint256 deadline,bool partiallyFillable,bytes32 salt)"
    );
    /// @dev EIP-712 type hash for a SpotSwapConductor order.
    bytes32 internal constant ORDER = keccak256(
        "Order(uint64 ownerChainId,address owner,bytes32 sellTokenId,bytes32 buyTokenId,uint256 sellAmount,uint256 buyAmount,uint64 receiverChainId,address receiver,uint256 expiresAt,bool partiallyFillable,bytes32 salt)"
    );
    /// @dev EIP-712 type hash for a DelayedSettlementSwapConductor order.
    bytes32 internal constant DELAYED_SETTLEMENT_ORDER = keccak256(
        "DelayedSettlementOrder(uint64 ownerChainId,address owner,bytes32 sellTokenId,bytes32 buyTokenId,uint256 sellAmount,uint256 buyAmount,uint64 receiverChainId,address receiver,uint256 expiresAt,bool partiallyFillable,bool delayedSettlement,uint256 settlementPeriod,bytes32 salt)"
    );

}
