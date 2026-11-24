FINDING claimed | Turnstile | _executeMessageLocally | oog-heuristic-nested-call — ORCHESTRATOR GATE: agent's own numbers leave ~1,090 gas; Failed path then needs SSTORE + emit MessageFailed (3 topics + ~256B data ≈ 3.5k gas) → OOG → whole delivery reverts → CCIP manual exec. Window requires token cost >~130k. Gate 1 interrupts → LEAD.
LEAD | Turnstile | _executeMessageLocally | oog-heuristic-nested-call (deposit path; facilitator-chosen messageGas not signed)
LEAD | Turnstile | _isRoutable | routing-guard-misses-role-forwarder (target under different AccessManager returns role 0)
