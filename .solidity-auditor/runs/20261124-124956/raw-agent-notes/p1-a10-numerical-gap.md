FINDING | DelayedSettlementSwapConductor | repay/_escrowLeg | unvalidated-receiver-blocks-repay (same root; fix revert BadPair in _escrowLeg)
LEAD | Turnstile | _executeMessageLocally | oog-heuristic-nested-call — 1/63 assumes single frame; proxy token / deposit path nested frames leave ~0.031G > G/63 → Failed instead of revert; unverified enough gas remains for SSTORE+event with USDC costs.
LEAD | HubWarehouseConductor | receiveDeposit | over-reservation-blocks-deposit-fee — recipient reservation > balance makes fee transfer revert; deposit Failed until request consumed.
