FINDING claimed | Turnstile | _executeMessageLocally | oog-heuristic-nested-call — ORCHESTRATOR GATE: at G~40k residual ~0.031G≈1.2k < Failed SSTORE(dirty,100)+MessageFailed LOG(~3k+) → tx OOG-reverts → CCIP manual exec available; at G≥~130k token transfer (~35-60k) does not OOG. Agents p2-a12, p3? concur. Keep LEAD.
FINDING re: pause-blocks-deadline-repay (Turnstile variant). fix alt: Let reclaim refund the collateral of a leg whose repay message was dispatched before the deadline.
LEAD | Turnstile | _executeMessageLocally | missing-action-source-binding — Withdrawal branch accepts any source chain; compromised spoke can release hub VAULT; no ActionType↔direction binding.
LEAD re: routing-guard-misses-role-forwarder.
