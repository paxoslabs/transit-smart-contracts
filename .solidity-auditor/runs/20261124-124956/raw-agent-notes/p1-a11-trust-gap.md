FINDING | DelayedSettlementSwapConductor | _escrowLeg | unvalidated-receiver-blocks-repay (same; solver can do it deliberately, breaks TA-2)
FINDING | DelayedSettlementSwapConductor | repay | pause-forfeits-collateral (same as a12 pause-blocks-deadline-repay; spoke Generic repay Failed + 48h retry > 1 day)
FINDING | DelayedSettlementSwapConductor | _releaseLeg | freeze-bypass-via-escrow-release (same as a12; alt-address colluder; admin can't seize from conductor account without shorting other escrows)
fix alt: In _release, revert or send the leg to its accountId when addressFreezeList().isFrozen(leg.accountId) is true.
fix pause alt: Extend each escrowDeadline by the Depot paused time since the escrow was created, or refund collateral at reclaim when the Depot was paused inside the window.
LEAD | Turnstile | _executeMessageLocally | oog-heuristic-nested-call (same)
LEAD | Turnstile | _requireDependency | cross-chain-dependson-ordering — spoke Executed at send; CCIP no ordering; [deposit, Generic repay dependsOn deposit] may arrive reversed → repay Failed → 48h retry after deadline → collateral lost.
