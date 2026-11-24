FINDING | DelayedSettlementSwapConductor | _fillOrders | fok-split-across-escrows — FoK order A split across pairs (A,B collateralized) + (A,C); sum check passes; (A,C) releases; B defaults; reclaim refunds A's half → FoK order half executed and filledAmount == sellAmount. B pays 1%.
description: A collateralized counterparty that does not repay leaves a fill-or-kill order half executed and fully used up, because the code checks fill-or-kill only on the batch total.
fix: In _escrowFill, revert NotPartiallyFillable when either order is not partiallyFillable and its fill.amounts entry differs from its sellAmount, so such an order fills in one pair only.
FINDING re: missing-receiver-validation.
LEAD re: unfunded-request-consumed-by-anyone (no unprivileged way to lower free balance found).
LEAD | DelayedSettlementSwapConductor | _settlementPeriod | uncollateralized-pair-period-check — unused period on uncollateralized pair checked vs MAX; index order matters; no loss.
