FINDING | DelayedSettlementSwapConductor | settle/_releaseLeg | unvalidated-receiver-blocks-release (same; fix in _checkOrders and SpotSwap _fillOrders; Spot/both-uncollat variant reverts batch)
FINDING | DelayedSettlementSwapConductor | repay | undelayed-user-outflow-breaks-batch — repay debits free balance immediately (no epoch delay); M front-runs SpotSwap.settle(E) with repay → transferAmong InsufficientBalance → batch reverts for all.
LEAD | Turnstile | _executeMessageLocally | oog-heuristic-false-failed (same)
LEAD | DelayedSettlementSwapConductor | _releaseLeg | frozen-escrow-release (same as freeze bypass)
