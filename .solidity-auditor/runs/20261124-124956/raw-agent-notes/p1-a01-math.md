No FINDINGs (math precision verified: reservation packing, fullMulDivUp, DS fee/collateral, transferAmong sums, OOG heuristic).
LEAD | Depot | _reserve | reservation-exceeds-balance — reservations not checked vs balance; pooled per account/asset; first-executed request gets 0/partial; no third-party gain found.
LEAD | Turnstile | _executeMessageLocally | oog-heuristic-false-positive — target reverting after >62/63 gas trips OOG → whole delivery reverts instead of Failed; no caller-controlled whitelisted target found.
LEAD | DelayedSettlementSwapConductor | _reclaim | reclaim-nonexistent-escrow — deadline 0 for released/nonexistent escrow; reclaim emits Reclaimed, no funds move.
LEAD | SpotSwapConductor | _fillOrders | epoch-based-expiry — solver fills after expiresAt up to epoch length (KI-18 repeat).
