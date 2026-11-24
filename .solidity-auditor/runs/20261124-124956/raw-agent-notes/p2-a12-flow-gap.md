FINDING | DelayedSettlementSwapConductor | repay | pause-blocks-deadline-repay (hub Turnstile pause variant; spoke owner NotOwner on direct call; reclaim open)
LEAD | Turnstile | _requireDependency | dependency-satisfied-on-send (spoke deposit + repay ordering)
LEAD | Turnstile | _dispatchWithdraw | dependency-blocks-expired-consume — _requireDependency runs before executeWithdrawal; expired request with never-executed dependsOn can never be consumed → reservation locked forever (owner-chosen dependsOn).
LEAD | Turnstile | setRoutable | routable-relay-bypass (= indirect forwarder / AccessManager.execute)
LEAD | Turnstile | _executeMessageLocally | oog-heuristic-nested-call (estimate needs token cost >125k → not shown)
