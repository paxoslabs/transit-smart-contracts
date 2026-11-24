FINDING | DelayedSettlementSwapConductor | repay | pause-blocks-deadline-repay (Turnstile-pause variant hits spoke owners only; hub owners repay directly)
fix alt: Let repay succeed after the deadline until someone calls reclaim, and add a grace period to reclaim that a pause cannot use up.
LEAD | SwapConductor | requestOrderCancellation | turnstile-pause-blocks-spoke-cancel (same; also requestWithdrawal/requestTransfer for spoke owners)
Re-derived (still present): missing-receiver-validation, missing-recipient-validation, invalid-destination-locks-reservation, unfunded-request-consumed-by-anyone, deposit-fee-blocked-by-reservation.
