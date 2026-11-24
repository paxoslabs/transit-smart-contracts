LEAD | Turnstile | _executeMessageLocally | oog-heuristic-nested-call (re-found, combined with third-party-message-gas-choice)
LEAD | Turnstile | _dispatchDeposit | vault-self-deposit-unbacked-mint — no from != VAULT check; VAULT dispatching deposit transfers VAULT→VAULT and mints to any account; needs VAULT operator. fix: revert when from == VAULT.
LEAD | Turnstile | _hasVaultAllowance | user-allowance-not-covered-by-route-guard (same as p2-a02 routable-guard-ignores-user-allowance)
LEAD | HubWarehouseConductor | executeWithdrawal | frozen-owner-zero-burn-blocks-consume — burn(…,0) still runs freeze/pause checks; frozen owner's request can't be consumed; reservation stuck to deadline. fix: skip burn when amount == 0.
NOTE: Role ids in docs stale (PreAudit says TURNSTILE=5 but agent read EPOCH=5/TURNSTILE=6?) — verify.
