FINDING | DelayedSettlementSwapConductor | _escrowLeg | unvalidated-receiver-blocks-repay
Attacker (non-collateralized side) signs order with invalid receiver (receiver=0 or receiverChainId=0); DS stores receiverAccountId unvalidated; victim's repay → _release → _releaseLeg → Depot.transferFrom(conductor→invalid) reverts InvalidAccount; repay always reverts; after deadline reclaim sends victim collateral to PENALTY and refunds attacker. Proof: V collateralized 10_000 USDC period 1h; A non-collat receiver=0 period 1 day; settle ok; V.repay reverts; reclaim: V loses 100 USDC collateral + fill.
description: An attacker who signs an order with an invalid receiver makes the counterparty's repay revert, so the counterparty forfeits its collateral at reclaim.
fix: In `_escrowLeg`, revert when `TransitAddressLib.isValid(receiverAccountId)` is false, before the leg is stored.
LEAD | HubWarehouseConductor | executeWithdrawal | missing-recipient-validation — to=address(0) burns hub balance; spoke release fails forever (user-signed).
LEAD | HubWarehouseConductor | receiveDeposit | deposit-fee-blocked-by-reservation — fee transferFrom fails when recipient reservation > balance; deposit Failed until retry.
LEAD | UserConductor | executeTransfer | invalid-destination-locks-reservation — toChainId==0 reverts every execution; reservation locked until deadline (owner-created).
