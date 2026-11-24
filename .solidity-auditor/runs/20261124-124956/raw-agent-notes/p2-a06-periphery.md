LEAD | Turnstile | _hasVaultAllowance | routing-guard-ignores-user-allowances (same as user-allowance)
LEAD | Turnstile | _isRoutable | routing-guard-misses-sender-gated-target (same as p2-a02)
LEAD | SpotSwapConductor | _fillOrders | epoch-based-expiry (worse: user can't stop fill for up to 24h; also DS _checkOrders)
LEAD | DelayedSettlementSwapConductor | constructor | unvalidated-recipient-immutables — PENALTY/SURPLUS ids unchecked; invalid → reclaim/fee release revert forever; deploy-config only.
