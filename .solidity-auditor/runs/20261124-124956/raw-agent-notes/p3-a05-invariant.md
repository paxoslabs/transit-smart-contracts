FINDING re: pause-blocks-deadline-repay (Turnstile pause + bridge latency variant, spoke owners).
fix alt: Make reclaim refund the collateral when the protocol was paused during the period, or extend escrowDeadline by the paused time.
LEAD | UserConductor | executeTransfer | invalid-destination-locks-reservation — to==0 check before _consume and deadline branch → zero-`to` request never consumable even after deadline → reservation forever.
