LEAD | Turnstile | setRoutable | indirect-turnstile-role-forwarder — AccessManager.execute (role ADMIN) passes guards; if whitelisted, Generic → execute(HWC.receiveDeposit) runs with Turnstile's TURNSTILE role → unbacked mint. fix: reject target == authority() and targets holding roles granted to Turnstile.
LEAD | HubWarehouseConductor | receiveDeposit | deposit-fee-blocked-by-frozen-recipient — frozen to ≠ from with fee → Failed forever while frozen. fix: skip fee when to frozen (mint full).
LEAD | Turnstile | _dispatchDeposit | assumed-amount-fee-on-transfer — USDT dormant fee switch → mints > received. fix: balance-diff.
LEAD re: unfunded-request-consumed-by-anyone, third-party-message-gas-choice, undelayed-user-outflow-breaks-batch (only unprivileged immediate free-balance reducer), failed-withdrawal-no-recovery
FINDING re: pause-blocks-deadline-repay (re-verified)
