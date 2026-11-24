FINDING | DelayedSettlementSwapConductor | repay/_escrowLeg | unvalidated-receiver-blocks-release (same root; solver simulation only catches both-uncollateralized case)
LEAD | HubWarehouseConductor | executeWithdrawal | unvalidated-withdrawal-recipient — to=0 never rejected; burn then spoke fails forever or tokens lost (owner self-harm).
LEAD | Turnstile | _dispatchWithdraw | third-party-message-gas-choice — anyone dispatches effective withdrawal at minimumMessageGas.
