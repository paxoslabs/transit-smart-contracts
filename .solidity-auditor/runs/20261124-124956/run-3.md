# Run 3 — solidity-auditor

<!--RUN pass=3 of=3 stamp=20261124-124956 sha=81b4e5f agents=12/12-->

Pass 3 of 3 · 2026-11-24 · `81b4e5f` · 12/12 agents returned.

## Findings

<!--F key=ccipmessagingadapter|-buildmessage|receiver-rejects-requested-finality conf=95 kind=FINDING agents=1-->

[95] **The adapter requests safe-head finality that its own receiver rejects**

`CCIPMessagingAdapter._buildMessage` · Confidence: 95

**Description**
The adapter sends with `WAIT_FOR_SAFE_FLAG` but inherits a receiver config that allows only full finality, so the OffRamp rejects every message and no deposit or withdrawal arrives.

**Fix (Option A — accept the requested finality)**:

```diff
+    function getCCVsAndFinalityConfig(uint64, bytes calldata)
+        external
+        pure
+        override
+        returns (address[] memory, address[] memory, uint8, bytes4)
+    {
+        return (new address[](0), new address[](0), 0, FinalityCodec.WAIT_FOR_SAFE_FLAG);
+    }
```

**Fix (Option B — request full finality)**:

```diff
-            extraArgs: ExtraArgsCodec._getBasicEncodedExtraArgsV3FastConfirmationRule(SafeCastLib.toUint32(gasLimit))
+            extraArgs: ExtraArgsCodec._getBasicEncodedExtraArgsV3(SafeCastLib.toUint32(gasLimit), FinalityCodec.WAIT_FOR_FINALITY_FLAG)
```

<!--/F-->

<!--F key=delayedsettlementswapconductor|-escrowleg|missing-receiver-validation conf=90 kind=FINDING agents=2-->

[90] **An invalid receiver on one order makes the counterparty forfeit its collateral**

`DelayedSettlementSwapConductor._escrowLeg` · Confidence: 90

**Description**
An attacker signs an order with a zero receiver or receiver chain, so every `repay` by the collateralized counterparty reverts and `reclaim` sends its collateral to the penalty recipient.

**Fix**

```diff
+        bytes28 receiverAccountId = TransitAddressLib.formatTransitAddress(order.receiverChainId, order.receiver);
+        if (!TransitAddressLib.isValid(receiverAccountId)) revert BadPair(index);
         escrowLegs[escrowId][side] = Leg({
             accountId: ownerAccountIds[orderIndex],
-            receiverAccountId: TransitAddressLib.formatTransitAddress(order.receiverChainId, order.receiver),
+            receiverAccountId: receiverAccountId,
```

<!--/F-->

<!--F key=delayedsettlementswapconductor|-releaseleg|freeze-bypass-escrow-release conf=80 kind=FINDING agents=2-->

[80] **A frozen user's open escrow still pays an unfrozen receiver**

`DelayedSettlementSwapConductor._releaseLeg` · Confidence: 80

**Description**
When a frozen user's counterparty repays, `_releaseLeg` debits only the conductor account, so the frozen user's escrowed tokens pay out to a receiver that the user chose.

**Fix (Option A — take the reclaim path for a frozen leg)**:

```diff
     function _release(uint256 escrowId) internal {
         Leg[2] memory legs = escrowLegs[escrowId];
+        IAddressFreezeList freezeList = IDepot(DEPOT).addressFreezeList();
+        if (freezeList.isFrozen(legs[0].accountId) || freezeList.isFrozen(legs[1].accountId)) {
+            // refund both legs to their owners so the admin can seize the frozen side
+        }
```

**Fix (Option B — redirect frozen proceeds to the owner account)**:

```diff
-            .transferFrom(conductorAccountId, counterparty.receiverAccountId, leg.assetId, leg.amount - leg.fee);
+            .transferFrom(
+                conductorAccountId,
+                frozen(counterparty.accountId) ? counterparty.accountId : counterparty.receiverAccountId,
+                leg.assetId,
+                leg.amount - leg.fee
+            );
```

<!--/F-->

<!--F key=delayedsettlementswapconductor|repay|pause-blocks-deadline-repay conf=75 kind=FINDING agents=5-->

[75] **A pause across an escrow deadline makes a willing payer lose its collateral**

`DelayedSettlementSwapConductor.repay` · Confidence: 75

**Description**
A Depot pause, or a Turnstile pause for a spoke owner, blocks `repay` but not `reclaim`, so after the deadline any caller sends an honest payer's collateral to the penalty recipient.

**Fix (Option A — extend deadlines by paused time)**:

```diff
-        if (block.timestamp > escrowDeadline[escrowId]) revert SettlementPeriodOver();
+        if (block.timestamp > escrowDeadline[escrowId] + IDepot(DEPOT).pausedDurationSince(escrowCreatedAt[escrowId])) {
+            revert SettlementPeriodOver();
+        }
```

**Fix (Option B — accept late payment until reclaim)**:

```diff
-        if (block.timestamp > escrowDeadline[escrowId]) revert SettlementPeriodOver();
+        if (escrowDeadline[escrowId] == 0) revert SettlementPeriodOver();
```

**Fix (Option C — block reclaim while paused)**:

```diff
     function _reclaim(uint256 escrowId) internal {
         if (block.timestamp <= escrowDeadline[escrowId]) revert SettlementPeriodActive();
+        if (Pausable(address(TURNSTILE)).paused()) revert EnforcedPause();
```

<!--/F-->

<!--F key=delayedsettlementswapconductor|-fillorders|fok-split-across-escrows conf=75 kind=FINDING agents=1-->

[75] **A fill-or-kill order split across escrows can execute only in part**

`DelayedSettlementSwapConductor._fillOrders` · Confidence: 75

**Description**
The fill-or-kill check uses only the batch total, so a collateralized counterparty that defaults on one pair leaves the order half filled and fully used.

**Fix (Option A — fill-or-kill per pair)**:

```diff
+        // in _escrowFill, for each side:
+        if (!order.partiallyFillable && fill.amounts[side] != order.sellAmount) revert NotPartiallyFillable(orderHash);
```

**Fix (Option B — ban the risky pairing)**:

```diff
+        // reject a fill-or-kill order that appears in more than one PairedFill or is paired with a collateralized order
```

<!--/F-->

## Leads

<!--F key=turnstile|-isroutable|routing-guard-misses-role-forwarder kind=LEAD agents=7-->

- **The routing guard misses targets that forward the Turnstile's authority** — `Turnstile._isRoutable` — Code smells: `_isTurnstileOnly` checks only a direct TURNSTILE role in the Turnstile's own authority; `MessagingAdapter.send` and `AccessManager.execute` pass. — If an admin whitelists either one, any Generic sender can forge a Withdrawal message or mint through `receiveDeposit`. This needs an admin whitelist error.

<!--/F-->

<!--F key=turnstile|-hasvaultallowance|routing-guard-ignores-user-allowances kind=LEAD agents=1-->

- **The routing guard ignores user allowances to the Turnstile** — `Turnstile._hasVaultAllowance` — Code smells: only `allowance(VAULT, Turnstile)` is checked. — A routed token with no VAULT allowance lets a Generic sender spend users' deposit approvals. This needs an admin to route the token.

<!--/F-->

<!--F key=turnstile|-executemessagelocally|oog-heuristic-nested-call kind=LEAD agents=5-->

- **The out-of-gas check misses an out-of-gas error in a nested call** — `Turnstile._executeMessageLocally` — Code smells: `gasleft() <= gasBefore / 63` assumes one call frame; any caller picks `messageGas` for another user's withdrawal. — Two agents claim a Failed release; the gas left (about 1,100) cannot pay for the Failed write and the `MessageFailed` event, so the delivery reverts for a bridge retry. Not proven for normal token costs.

<!--/F-->

<!--F key=turnstile|-executemessagelocally|missing-action-source-binding kind=LEAD agents=1-->

- **The hub accepts a Withdrawal message from any spoke** — `Turnstile._executeMessageLocally` — Code smells: no check ties a Withdrawal message to source chain == hub. — A compromised spoke Turnstile or adapter can release hub VAULT tokens. This needs a peer compromise (TA-3).

<!--/F-->

<!--F key=turnstile|-executemessagelocally|depot-pause-forces-failed-deposit kind=LEAD agents=1-->

- **A Depot pause turns every in-flight message into a Failed message** — `Turnstile._executeMessageLocally` — Code smells: a Depot pause fails the conductor call inside the try, while a Turnstile pause reverts for a bridge retry. — The pauser can make all in-flight deposits wait for a 48h admin `retry` each.

<!--/F-->

<!--F key=turnstile|-dispatchwithdraw|third-party-message-gas-choice kind=LEAD agents=1-->

- **Any caller picks the message gas for another user's withdrawal** — `Turnstile._dispatchWithdraw` — Code smells: `messageGas` is not signed; only `minimumMessageGas` bounds it. — The harm depends on the configured minimum.

<!--/F-->

<!--F key=turnstile|-requiredependency|dependency-satisfied-on-send kind=LEAD agents=3-->

- **dependsOn passes when the parent message is only sent** — `Turnstile._requireDependency` — Code smells: the source marks a message Executed before `send`; CCIP keeps no order. — A spoke repay that depends on a deposit can reach the hub first and fail; the user can resend with a new salt.

<!--/F-->

<!--F key=hubwarehouseconductor|executewithdrawal|facilitated-withdrawal-replay-after-conductor-swap kind=LEAD agents=1-->

- **A facilitated withdrawal signature can run again after a conductor swap** — `HubWarehouseConductor.executeWithdrawal` — Code smells: replay state lives in the old conductor; a different executed amount gives a new message body. — The solver can withdraw a partially fillable action a second time after `setHubWarehouseConductor`.

<!--/F-->

<!--F key=hubwarehouseconductor|hashwithdrawalaction|hash-name-mismatch kind=LEAD agents=1-->

- **Two hashWithdrawalAction functions return different hashes** — `HubWarehouseConductor.hashWithdrawalAction` — Code smells: the conductor returns a raw struct hash; the Turnstile returns the EIP-712 digest. — An integrator who looks up a request with the Turnstile hash finds nothing. No on-chain path mixes them.

<!--/F-->

<!--F key=userconductor|executetransfer|frozen-owner-zero-burn-blocks-consume kind=LEAD agents=2-->

- **A zero transfer reverts for a frozen owner, so its request cannot be consumed** — `UserConductor.executeTransfer` — Code smells: `transferFrom(account, to, asset, 0)` still runs the freeze check. — The frozen owner's reservation stays until the request deadline.

<!--/F-->

<!--F key=userconductor|executetransfer|invalid-destination-locks-reservation kind=LEAD agents=1-->

- **A transfer request to a zero address can never be consumed** — `UserConductor.executeTransfer` — Code smells: the `to == address(0)` check runs before `_consume` and before the deadline branch. — The owner's reservation stays forever. Only the owner can sign this request.

<!--/F-->

<!--F key=requestconductor|-consume|unfunded-request-consumed-by-anyone kind=LEAD agents=1-->

- **Any caller can consume an underfunded request for zero** — `RequestConductor._consume` — Code smells: a short fill-or-kill request executes 0 and is marked EXECUTED. — The owner loses one epoch.

<!--/F-->

<!--F key=depot|-reserve|reservation-exceeds-balance kind=LEAD agents=1-->

- **The caller who executes pooled requests decides which one gets the funds** — `Depot._reserve` — Code smells: reservations form one pool per account and asset, and `reserve` never checks the balance. — A third party who picks the execution order decides which request moves funds and which is consumed for zero.

<!--/F-->

<!--F key=depot|-reserve|reservation-uint112-cap kind=LEAD agents=1-->

- **One request cannot reserve more than 2^112 base units** — `Depot._reserve` — Code smells: `toUint112` caps the reservation per account and asset. — A very large holder needs many requests. No whitelisted token reaches this size.

<!--/F-->

<!--F key=depot|-reserve|epoch-uint32-cast kind=LEAD agents=1-->

- **Reservations fail after 2^32 epochs** — `Depot._reserve` — Code smells: `pendingEpoch` is a `uint32` and empty settles advance the epoch. — About 4.3e9 settles are needed, so this is not practical.

<!--/F-->

<!--F key=depot|advanceepoch|solver-unbounded-epoch-advance kind=LEAD agents=1-->

- **The solver can advance the epoch many times with empty settles** — `Depot.advanceEpoch` — Code smells: both swap conductors accept empty batches and still advance. — Every conductor holds the full CONDUCTOR grant. No user loss found.

<!--/F-->

<!--F key=addressfreezelist|isfrozen|address-only-freeze-hits-protocol-account kind=LEAD agents=1-->

- **An address-only freeze can freeze protocol accounts** — `AddressFreezeList.isFrozen` — Code smells: the chainId is dropped, so a frozen address freezes the hub account of the same address. — A freeze of the DS conductor address blocks every escrow payout. Reachability not confirmed.

<!--/F-->

<!--F key=delayedsettlementswapconductor|-releaseleg|frozen-conductor-locks-escrows kind=LEAD agents=1-->

- **A freeze of the DS conductor address locks every escrow** — `DelayedSettlementSwapConductor._releaseLeg` — Code smells: every payout debits the conductor account, which the freeze check covers. — Release, repay and reclaim all fail until an unfreeze. This needs a freeze-manager mistake.

<!--/F-->

<!--F key=delayedsettlementswapconductor|-escrowleg|collateral-rounding-split-escrows kind=LEAD agents=1-->

- **Many tiny escrows raise the collateral above one percent** — `DelayedSettlementSwapConductor._escrowLeg` — Code smells: `divUp(amount, FILL_RATIO)` rounds up per escrow, not per order. — A solver that splits an order into many tiny pairs makes the owner post far more collateral. Not confirmed for a real token.

<!--/F-->

<!--F key=delayedsettlementswapconductor|repay|undelayed-user-outflow-breaks-batch kind=LEAD agents=1-->

- **repay debits the free balance with no epoch delay** — `DelayedSettlementSwapConductor.repay` — Code smells: `repay` lowers free balance at once. — A user can make the solver's batch revert. No funds are lost.

<!--/F-->

<!--F key=delayedsettlementswapconductor|repay|failed-cross-chain-repay-forfeits-collateral kind=LEAD agents=1-->

- **A failed cross-chain repay cannot be retried before the deadline** — `DelayedSettlementSwapConductor.repay` — Code smells: admin `retry` takes 48h, longer than the 1-day maximum period. — The user must resend before the deadline; a retry never saves the repay.

<!--/F-->

<!--F key=delayedsettlementswapconductor|-settlementperiod|uncollateralized-pair-period-check kind=LEAD agents=1-->

- **An unused period decides whether an uncollateralized pair settles** — `DelayedSettlementSwapConductor._settlementPeriod` — Code smells: the second order's period is checked when neither side is collateralized. — A valid match can fail. No loss.

<!--/F-->

<!--F key=delayedsettlementswapconductor|-reclaim|reclaim-nonexistent-escrow kind=LEAD agents=1-->

- **reclaim emits Reclaimed for an escrow that does not exist** — `DelayedSettlementSwapConductor._reclaim` — Code smells: a deleted escrow has deadline 0. — Indexers can record false reclaims.

<!--/F-->
