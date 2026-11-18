// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.37;

import { IRequestConductor } from "src/interfaces/IRequestConductor.sol";
import { ITurnstile } from "src/interfaces/ITurnstile.sol";

/// @title Transit Terminal HubWarehouseConductor
/// @notice Hub-side handling of deposits and withdrawals: mints deposited balances and burns withdrawn ones.
interface IHubWarehouseConductor is IRequestConductor {

    /// @notice A withdrawal request was executed.
    /// @param requestId Request id.
    /// @param amount Amount burned for withdrawal.
    event WithdrawalExecuted(bytes32 indexed requestId, uint256 amount);

    /// @notice Request a withdrawal, reserving the funds from the next epoch. The sender must be the owner.
    /// @param action Withdrawal action.
    function requestWithdrawal(ITurnstile.WithdrawalAction calldata action) external;

    /// @notice Credit a deposit received by the Turnstile. Mints to the recipient, then transfers the facilitation fee
    /// from the recipient to the fee receiver. A frozen sender's deposit is minted whole to its own account, with no
    /// fee.
    /// @dev Must never be in the Turnstile's genericMessageWhitelist: generic calls also arrive from the Turnstile and
    /// pass `restricted`, so anyone could mint unbacked balance. Only a Deposit message, sent after custody, may call
    /// it.
    /// @param sourceChainId Chain the deposit was made on.
    /// @param asset Address of the deposited asset on the source chain.
    /// @param amount Amount deposited.
    /// @param fromAccountId Depositing account.
    /// @param toAccountId Recipient account.
    /// @param facilitationFee Part of amount paid from the recipient to feeReceiverAccountId; 0 for none.
    /// @param feeReceiverAccountId Facilitation fee receiver account.
    function receiveDeposit(
        uint64 sourceChainId,
        address asset,
        uint256 amount,
        bytes28 fromAccountId,
        bytes28 toAccountId,
        uint256 facilitationFee,
        bytes28 feeReceiverAccountId
    )
        external;

    /// @notice Execute an effective withdrawal request, burning up to the executable amount. Called by the Turnstile.
    /// @dev Must never be in the Turnstile's genericMessageWhitelist: generic calls also arrive from the Turnstile and
    /// pass `restricted`, but only a Withdrawal dispatch sends the release message for the returned amount. A generic
    /// call would burn the owner's balance with no payout, and anyone could do it to any effective request.
    /// @param action Withdrawal action.
    /// @return amount Amount burned; 0 if expired or unfillable.
    function executeWithdrawal(ITurnstile.WithdrawalAction calldata action) external returns (uint256 amount);

    /// @notice Hash of a withdrawal action, used as its request id.
    /// @param action Withdrawal action.
    /// @return Request id.
    function hashWithdrawalAction(ITurnstile.WithdrawalAction memory action) external pure returns (bytes32);

}
