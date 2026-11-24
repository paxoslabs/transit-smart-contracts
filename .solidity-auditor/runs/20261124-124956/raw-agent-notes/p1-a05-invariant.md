FINDING | DelayedSettlementSwapConductor | _escrowLeg | unvalidated-receiver-blocks-repay (same; partially fillable attacker order hits many victims)
LEAD | DelayedSettlementSwapConductor | repay | pause-across-deadline-forfeits-collateral (same pause issue)
LEAD | SpotSwapConductor | _fillOrders | epoch-based-expiry-stale-fill (KI-18)
LEAD | RequestConductor | _consume | unfunded-request-consumed-by-anyone — anyone executes underfunded effective fill-or-kill request → EXECUTED with 0; one epoch delay.
