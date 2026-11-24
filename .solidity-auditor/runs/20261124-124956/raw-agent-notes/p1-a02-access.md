FINDING | Turnstile | _executeMessageLocally | oog-heuristic-third-party-gas
Anyone dispatches victim's effective withdrawal with tuned low messageGas (minimumMessageGas=0 in reference wiring); spoke trySafeTransferFrom OOGs inside proxied token (nested frame) so gasleft() > gasBefore/63 → marked Failed instead of revert; CCIP sees success; only ADMIN retry (48h). Proof: caller keeps ~0.031G > G/63 when G > ~32k; USDC transferFrom needs 35-50k.
description: Any caller dispatches another user's effective withdrawal with a low messageGas, so the spoke marks the release Failed and the user waits for an admin retry.
fix: Make the out-of-gas check also fire when the call returns no data, or bind `messageGas` to a signed value or a safe `minimumMessageGas` for withdrawal messages.
FINDING | DelayedSettlementSwapConductor | _escrowLeg | unvalidated-receiver-blocks-release (same as agent 8) — fix also in SpotSwap _fillOrders (there it only reverts batch).
LEAD | Turnstile | _dispatchWithdraw | third-party-dispatch-params — anyone chooses messageGas/timing for effective withdrawal.
