FINDING | DelayedSettlementSwapConductor | repay | pause-blocks-deadline-repay
PAUSER pauses Depot (or hub Turnstile for spoke repay) across escrowDeadline; repay reverts; after unpause SettlementPeriodOver; reclaim sends honest payer collateral to PENALTY. Spoke Generic repay Failed → ADMIN retry 48h > MAX_SETTLEMENT_PERIOD.
description: The PAUSER can pause the Depot until a repay deadline passes, so anyone can then reclaim and send an honest payer's collateral to the penalty recipient.
fix: Record the paused time and add it to escrowDeadline, or let repay succeed after a deadline that fell inside a pause window.
FINDING | DelayedSettlementSwapConductor | _releaseLeg | freeze-bypass-escrow-release
Frozen user U with open escrow (non-collat, receiver R≠U); colluder C repays; _release transfers from conductor account (freeze check only on conductor) → U's proceeds go to R. Escrowed value escapes freeze/seizure.
description: A frozen user and a colluder can finish an open delayed-settlement escrow, so the frozen user's escrowed tokens pay out to an unfrozen receiver.
fix: In _release, check addressFreezeList.isFrozen for each leg.accountId, and route a frozen owner's proceeds back to leg.accountId (or refund that leg) so the admin can seize them.
LEAD | Turnstile | _requireDependency | dependency-satisfied-on-send — Executed set on source before send; dependsOn on spoke = "sent", not executed on hub; withdrawal to spoke Executed on hub even if spoke release Failed.
LEAD | Turnstile | _executeMessageLocally | oog-heuristic-nested-call — nested OOG marked Failed; agent's gas math says residual covers SSTORE+emit only when G ≳ 160k, so third-party withdrawal path looks impossible.
