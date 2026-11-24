FINDING | DelayedSettlementSwapConductor | _escrowLeg | missing-receiver-validation (same root; second effect: both non-collateralized → settle _release reverts whole batch)
LEAD | Turnstile | _executeMessageLocally | oog-heuristic-false-negative (same)
LEAD | DelayedSettlementSwapConductor | _releaseLeg | freeze-bypass-escrow-release (same)
LEAD | Turnstile | _requireDependency | cross-chain-dependency-sent-not-executed (same; fee depending on hub→spoke withdrawal passes though release Failed)
