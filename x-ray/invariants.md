# Invariant Map

> Transit Contracts | 46 guards | 28 inferred (17 single-contract, 8 cross-contract, 3 economic) | 10 not enforced on-chain

---

## 1. Enforced Guards (Reference)

Per-call preconditions. Heading IDs below (`G-N`) are anchor targets from x-ray.md attack surfaces.

#### G-1
`if (!TransitAddressLib.isValid(fromAccountId) || !TransitAddressLib.isValid(toAccountId)) revert InvalidAccount()` · `Depot.sol:70-71` · Keeps the bytes28(0) mint/burn sentinel and half-set ids out of ledger transfers.

#### G-2
`_requireNotFrozen(fromAccountId)` → `if (addressFreezeList.isFrozen(accountId)) revert AccountFrozen(accountId)` · `Depot.sol:73,195` · Compliance freeze: frozen accounts can receive but never be debited by a conductor.

#### G-3
`if (freeBalanceOf(fromAccountId, assetId) < amount) revert InsufficientBalance()` · `Depot.sol:74` · Effective reservations are unspendable by any conductor transfer; also prevents underflow.

#### G-4
`if (delta.fromAccountId == bytes28(0) && delta.toAccountId == bytes28(0)) revert EmptyDelta()` · `Depot.sol:88` · A delta must move value somewhere; blocks no-op padding that could skew per-asset sums.

#### G-5
`if (delta.amount == 0) revert ZeroAmount()` · `Depot.sol:89` · Solver batches cannot contain zero deltas.

#### G-6
`if (!TransitAddressLib.isValid(assetId)) revert InvalidAsset()` · `Depot.sol:92` · Asset ids in batches must be real (chainId, token) pairs.

#### G-7
`if (freeBalanceOf(delta.fromAccountId, assetId) < delta.amount) revert InsufficientBalance()` · `Depot.sol:111` · Per-debit free-balance check inside a batch, evaluated in delta order (credits placed first by SpotSwap).

#### G-8
`if (debits[assetIndex] != credits[assetIndex]) revert NotZeroSum()` · `Depot.sol:130` · Solver batches cannot mint or burn net value per asset.

#### G-9
`if (!TransitAddressLib.isValid(toAccountId)) revert InvalidAccount()` · `Depot.sol:136` · Mints only to valid accounts.

#### G-10
`if (freeBalanceOf(fromAccountId, assetId) < amount) revert InsufficientBalance()` · `Depot.sol:145` · Burns (withdrawals) cannot consume reserved funds.

#### G-11
`if (res.effective < amount) revert ReleaseExceedsReserved(amount, res.effective)` · `Depot.sol:225` · Only effective reservations can be released; pending amounts are untouchable.

#### G-12
`SafeCastLib.toUint112(uint256(res.effective) + res.pending + amount)` · `Depot.sol:216` · Caps total reservation so packed fields cannot overflow on roll.

#### G-13
`if (block.timestamp < lastEpochAdvancedAt + 24 hours) _checkCanCall(_msgSender(), _msgData())` · `Depot.sol:164` · Epoch advances are role-gated except after 24h of inactivity (liveness escape hatch).

#### G-14
`if (address(_addressFreezeList).code.length == 0) revert NoCode()` · `Depot.sol:199` · Freeze list must be a contract; an EOA would make every debit revert on decode.

#### G-15
`if (senderAccountId != ownerAccountId) revert NotOwner()` · `RequestConductor.sol:35` · Only the owner account (incl. chain) can create a request that reserves its funds.

#### G-16
`if (requestEffectiveAtEpoch[senderAccountId][requestId] != 0) revert RequestReplay()` · `RequestConductor.sol:36` · A request id (struct hash) can be queued once.

#### G-17
`if (effectiveAtEpoch == EXECUTED) revert RequestReplay()` · `RequestConductor.sol:46` · A request executes at most once.

#### G-18
`if (effectiveAtEpoch == 0 || IDepot(DEPOT).settlementEpoch() < effectiveAtEpoch) revert NotEffective()` · `RequestConductor.sol:74` · Non-facilitated execution waits for the request's epoch so it cannot invalidate an in-flight batch.

#### G-19
`if (request.to == address(0)) revert ZeroAddress()` · `UserConductor.sol:34` · Prevents transfers to an invalid recipient account.

#### G-20
`if (accountId != TransitAddressLib.formatTransitAddress(order.ownerChainId, order.owner)) revert NotOwner()` · `SpotSwapConductor.sol:39` · Pre-approval only by the order's owner account (contract-wallet path in lieu of 1271).

#### G-21
`if (epoch != IDepot(DEPOT).settlementEpoch()) revert BadEpoch(epoch)` · `SpotSwapConductor.sol:49` · Batch built for a stale epoch cannot settle after cancels/requests changed.

#### G-22
`if (order.expiresAt <= lastEpochAdvancedAt) revert Expired(orderHash)` · `SpotSwapConductor.sol:84` · Epoch-based order expiry.

#### G-23
`if (!order.partiallyFillable && fill.sellFilled != order.sellAmount) revert NotPartiallyFillable(orderHash)` · `SpotSwapConductor.sol:85-86` · Fill-or-kill per fill entry.

#### G-24
`if (fill.buyFilled < FixedPointMathLib.fullMulDivUp(fill.sellFilled, order.buyAmount, order.sellAmount)) revert LimitPrice(orderHash)` · `SpotSwapConductor.sol:90-91` · The user's signed limit price is the only settlement guarantee.

#### G-25
`if (!preApproved[orderHash]) revert NotPreApproved(orderHash)` · `SwapConductor.sol:69` · Empty signature is only valid for orders the owner approved on-chain.

#### G-26
`ECDSA.recoverCalldata(orderHash, signature) != owner → revert BadSignature()` · `SwapConductor.sol:70-71` · Orders authorized by owner key (ECDSA only).

#### G-27
`if (filled > sellAmount) revert Overfill(orderHash)` · `SwapConductor.sol:88` · Cumulative fills capped by signed sellAmount.

#### G-28
`if (cancelledFromEpoch != 0 && settlementEpoch >= cancelledFromEpoch) revert Cancelled(orderHash)` · `SwapConductor.sol:91` · Effective cancellations block fills.

#### G-29
`if (block.timestamp > escrowDeadline[escrowId]) revert SettlementPeriodOver()` · `DelayedSettlementSwapConductor.sol:65` · Repayment window closes at the escrow deadline.

#### G-30
`if (_senderAccountId() != leg.accountId) revert NotOwner()` · `DelayedSettlementSwapConductor.sol:68` · Only the leg owner repays its debt.

#### G-31
`if (amount == 0) revert NothingOwed()` · `DelayedSettlementSwapConductor.sol:70` · No repay on a paid or non-collateralized leg.

#### G-32
`if (block.timestamp <= escrowDeadline[escrowId]) revert SettlementPeriodActive()` · `DelayedSettlementSwapConductor.sol:91` · Reclaim only after the repayment window.

#### G-33
`if (orders.length != signatures.length) revert LengthMismatch()` · `DelayedSettlementSwapConductor.sol:133` · One signature slot per order.

#### G-34
`fill.orderIndexes[0] == fill.orderIndexes[1] || token mismatch || fill.amounts[i] == 0 → revert BadPair(index)` · `DelayedSettlementSwapConductor.sol:209-216` · Pairs must be two distinct orders with mirrored tokens and non-zero amounts.

#### G-35
`fill.amounts[counterpartySide] - fill.fees[counterpartySide] < fullMulDivUp(amount, order.buyAmount, order.sellAmount) → revert LimitPrice` · `DelayedSettlementSwapConductor.sol:246-250` · Each leg receives at least its limit after the counterparty's fee.

#### G-36
`settlementPeriod > MAX_SETTLEMENT_PERIOD || collateralized side period > other side's → revert BadPair(index)` · `DelayedSettlementSwapConductor.sol:286-291` · Bounds the debt window and stops a collateralized side imposing a longer wait than its counterparty accepted.

#### G-37
`if (!order.partiallyFillable && sellFilled[i] != order.sellAmount) revert NotPartiallyFillable(orderHash)` · `DelayedSettlementSwapConductor.sol:342` · Fill-or-kill aggregated across all pairs in the batch.

#### G-38
`if (allowed && _hasVaultAllowance(target)) revert VaultApprovedTarget(target)` · `Turnstile.sol:83` · Generic calls must never reach a token the VAULT approved to this Turnstile.

#### G-39
`if (allowed && _isTurnstileOnly(target, selectors[i])) revert TurnstileOnlySelector(target, selectors[i])` · `Turnstile.sol:87-88` · Turnstile-only conductor functions (receiveDeposit, executeWithdrawal) can't be whitelisted.

#### G-40
`if (block.chainid != IMessagingAdapter(messagingAdapter).HUB_CHAIN_ID()) revert NotHubChain()` · `Turnstile.sol:74` · Warehouse conductor exists only on the hub.

#### G-41
`if (messageStatus[messageHash] != MessageStatus.Failed) revert NotFailed()` · `Turnstile.sol:252` · Only Failed messages can be retried.

#### G-42
`if (totalBridgeFee != msg.value) revert BridgeFeeMismatch()` · `Turnstile.sol:288` · Exact bridge-fee accounting per dispatch batch.

#### G-43
`if (action.ownerChainId != block.chainid || from != action.owner) revert NotOwner()` · `Turnstile.sol:336,417` · Deposits/generics act only for the local sender or signer.

#### G-44
`if (dependsOn != 0 && messageStatus[dependsOn] != MessageStatus.Executed) revert DependencyNotExecuted()` · `Turnstile.sol:431` · Dependent actions (e.g. fees) only execute after their dependency.

#### G-45
`if (messageStatus[messageHash] != MessageStatus.None) revert MessageReplay()` · `Turnstile.sol:448` · Every message hash is handled once (inbound and same-chain).

#### G-46
`if (peer.peer != sender) revert UnauthorizedPeer(chainId, sender)` / `if (!peer.allowMessagesFrom) revert MessagesNotAllowedFrom(chainId)` · `MessagingAdapter.sol:139-140` · Only the configured peer adapter of an allowed chain can deliver messages.

---

## 2. Inferred Invariants (Single-Contract)

Each block cites a Δ-pair, guard-lift + write sites, state edge, temporal predicate, or NatSpec claim. Categories: `Conservation` · `Bound` · `Ratio` · `StateMachine` · `Temporal`.

---

#### I-1

`Conservation` · On-chain: **Yes**

> Ledger moves are symmetric: every non-sentinel debit of `balanceOf[from][asset]` is matched by an equal credit to `balanceOf[to][asset]`; supply changes only through the bytes28(0) sentinel (mint/burn).

**Derivation** — Δ-pair: `Depot.sol:242 ↔ Depot.sol:243` (`_transfer` is the only writer of `balanceOf`).

**If violated** — Ledger supply diverges from custody; balances created from nothing.

---

#### I-2

`Conservation` · On-chain: **Yes**

> Every `transferAmong` batch nets to zero per asset (Σ debits == Σ credits), so solver batches never change per-asset supply.

**Derivation** — guard-lift: `if (debits[assetIndex] != credits[assetIndex]) revert NotZeroSum()` (`Depot.sol:130`); `transferAmong` is the only batch writer; per-delta accumulation at `Depot.sol:113,120`.

**If violated** — Solver mints value (e.g. unbacked fees to SURPLUS).

---

#### I-3

`Bound` · On-chain: **No**

> No debit ever exceeds the account's free balance (balance − effective reservations).

**Derivation** — guard-lift: `freeBalanceOf(...) < amount → InsufficientBalance` at `Depot.sol:74,111,145`. Write sites decreasing `balanceOf`: `transferFrom:75`, `transferAmong:123`, `burn:146` (guarded) and `forceTransferFrom:159` (**unguarded**; also skips pause/freeze/validity).

**If violated** — Reserved funds (pending withdrawals/transfers) are spent; requests later under-fill (free floors to 0).

---

#### I-4

`Bound` · On-chain: **Yes**

> `effective + pending ≤ type(uint112).max` for every reservation.

**Derivation** — guard-lift: `SafeCastLib.toUint112(effective + pending + amount)` (`Depot.sol:216`). Write sites: `_reserve:217` (guarded), `_rollReservation:234-235` (sum-preserving), `_release:226` (decreasing).

**If violated** — Roll overflow would brick releases for the account.

---

#### I-5

`StateMachine` · On-chain: **Yes**

> A reservation amount moves pending → effective once `pendingEpoch ≤ settlementEpoch`, and only effective amounts can leave via release.

**Derivation** — edge: `pending@Depot.sol:217 → effective@Depot.sol:234`; release gate `Depot.sol:225`; `_reserved` view mirrors the roll at `Depot.sol:208`.

**If violated** — Reservations could be released before taking effect or count before their epoch (breaks solver predictability).

---

#### I-6

`Temporal` · On-chain: **Yes**

> `settlementEpoch` is monotonically increasing and advances either by a CONDUCTOR-role caller or by anyone once 24h have passed since `lastEpochAdvancedAt`.

**Derivation** — temporal: `if (block.timestamp < lastEpochAdvancedAt + 24 hours) _checkCanCall(...)` (`Depot.sol:164`); only writer `++settlementEpoch` at `Depot.sol:166`.

**If violated** — Requests could never become effective (liveness) or batches could be replayed.

---

#### I-7

`StateMachine` · On-chain: **Yes**

> `requestEffectiveAtEpoch[account][id]` goes `0 → epoch+1 → EXECUTED` (or `0 → EXECUTED` for a facilitated owner), never back.

**Derivation** — edge: `0@RequestConductor.sol:36 → epoch+1@:39`; `* → EXECUTED@:47` guarded by `:46`.

**If violated** — Double execution of a withdrawal/transfer.

---

#### I-8

`StateMachine` · On-chain: **Yes**

> `messageStatus`: `None → Executed` on handling; `Executed → Failed` only for a cross-chain execution failure in the same call; `Failed → None → Executed|Failed` only through `retry`.

**Derivation** — edge: `None@Turnstile.sol:448 → Executed@:449`; `Executed → Failed@:566`; `Failed@:252 → None@:253` (retry, re-enters `_handleMessage`).

**If violated** — Message replay (double mint/release) or permanently stuck messages.

---

#### I-9

`Bound` · On-chain: **Yes**

> `filledAmount[orderHash] ≤ order.sellAmount` for every order, in each swap conductor.

**Derivation** — guard-lift: `if (filled > sellAmount) revert Overfill(orderHash)` (`SwapConductor.sol:88`); sole writer `SwapConductor.sol:89`.

**If violated** — Orders filled beyond the signed amount.

---

#### I-10

`Temporal` · On-chain: **Yes**

> A non-facilitated cancellation takes effect no earlier than `settlementEpoch + 1`; a facilitated one at `settlementEpoch`; the earliest recorded epoch wins.

**Derivation** — temporal: `effectiveAtEpoch = settlementEpoch(); if (!_facilitated()) effectiveAtEpoch++` (`SwapConductor.sol:57-58`); keep-earliest `:60`; sole writer `:61`.

**If violated** — Users could pull orders out of a locked batch (batch breakage / free option).

---

#### I-11

`Temporal` · On-chain: **Yes**

> For a live escrow, repay is possible only while `block.timestamp ≤ escrowDeadline` and reclaim only after; the windows are disjoint.

**Derivation** — temporal: `DelayedSettlementSwapConductor.sol:65` vs `:91`; deadline written once at `:220`.

**If violated** — Collateral could be both repaid and forfeited.

---

#### I-12

`Temporal` · On-chain: **No**

> `reclaim` only acts on live, unsettled escrows.

**Derivation** — temporal: guard `block.timestamp <= escrowDeadline[escrowId] → SettlementPeriodActive` (`DelayedSettlementSwapConductor.sol:91`). Write sites of `escrowDeadline`: set `:220`, deleted `:94` (reclaim) and `:299` (release). After deletion (or for a never-created id) the deadline is 0, so the guard passes and the call proceeds with zeroed legs.

**If violated** — Reclaim on released/nonexistent ids executes as a no-op and emits `Reclaimed`.

---

#### I-13

`Conservation` · On-chain: **Yes**

> The DS conductor's own Depot account holds exactly Σ over live escrows of each leg's posted amount (collateral or full amount) plus repaid debt.

**Derivation** — Δ-pair: in via settle deltas `DelayedSettlementSwapConductor.sol:266-268` and repay `:73`; out via release `:310-325` and reclaim `:107-115`; each leg's out-transfers sum to what it put in.

**If violated** — Escrow payouts revert (`InsufficientBalance`) or leak funds between escrows.

---

#### I-14

`Bound` · On-chain: **Yes**

> Every escrow's repayment window is ≤ `MAX_SETTLEMENT_PERIOD` (1 day).

**Derivation** — guard-lift: `settlementPeriod > MAX_SETTLEMENT_PERIOD → BadPair` (`DelayedSettlementSwapConductor.sol:287`); sole writer `escrowDeadline[...] = block.timestamp + _settlementPeriod(...)` `:220`.

**If violated** — Counterparty funds escrowed indefinitely.

---

#### I-15

`Conservation` · On-chain: **No**

> `chainIdForRemoteId[r] == c` iff `peers[c].remoteId == r` (peer config and reverse map stay a bijection).

**Derivation** — Δ-pair: `MessagingAdapter.sol:59 ↔ :61` (setPeer writes both) and `:70 ↔ :71` (removePeer deletes both). `setPeer` on an existing chain with a new remoteId does not delete the old `chainIdForRemoteId` entry, and reusing a remoteId for another chain leaves the first chain's `peers[c].remoteId` pointing at it.

**If violated** — Stale reverse mappings; a later `removePeer` of the old chain deletes the new chain's inbound mapping.

---

#### I-16

`Bound` · On-chain: **Yes**

> A Generic message executes only if `target.selector` is whitelisted, not mapped to the TURNSTILE role, and `target` reports no VAULT allowance to the Turnstile, evaluated at execution time.

**Derivation** — guard-lift: `_isRoutable` (`Turnstile.sol:583-587`) used at execution `:532`; set-time guards `:83,:88`; `genericMessageWhitelist` sole writer `:90`.

**If violated** — Generic calls could pull VAULT funds or mint unbacked deposits.

---

#### I-17

`Bound` · On-chain: **Yes**

> Outbound message gas is within `[minimumMessageGas, messageGasLimit]` of the destination peer, and the peer allows outbound messages.

**Derivation** — guard-lift: `MessagingAdapter.sol:163-165` in `_validateOutboundAndGetPeer`, used by `send:102` and `quote:110`; peer fields written by `setPeer:59`, `setAllowMessagesToChain:83`, `setPeerGasLimit:90`.

**If violated** — Under-gassed deliveries (OOG reverts → bridge retry) or sends to disabled chains.

---

## 3. Inferred Invariants (Cross-Contract)

---

#### X-1

On-chain: **No**

> The hub mints exactly what the source VAULT received.

**Caller side** — `Turnstile.sol:348` — `safeTransferFrom(asset, from, VAULT, action.amount)`; body carries `action.amount` with no balance-difference check.

**Callee side** — `HubWarehouseConductor.sol:62,65` — `Depot.mint(..., amount)` with the message amount.

**If violated** — Fee-on-transfer/rebasing assets leave Depot supply above custody for that asset (mitigated only by the asset whitelist).

---

#### X-2

On-chain: **Yes**

> The WithdrawalMessage amount equals the amount burned on the hub.

**Caller side** — `Turnstile.sol:398-403` — uses `executeWithdrawal`'s return as `WithdrawalMessage.amount`; amount 0 sends nothing.

**Callee side** — `HubWarehouseConductor.sol:89-90` — returns exactly the `amount` it burned.

**If violated** — Releases without burns (or burns without releases).

---

#### X-3

On-chain: **Yes**

> `_consume` releases exactly what `_request` reserved for that request id.

**Caller side** — `RequestConductor.sol:49` — `release(ownerAccountId, assetId, amount)` with amount from the action/request.

**Callee side** — `RequestConductor.sol:38` — `reserve(senderAccountId, assetId, amount)`; requestId is the struct hash (binds asset and amount), so both sides use identical values.

**If violated** — Reservations leak or `ReleaseExceedsReserved` bricks execution.

---

#### X-4

On-chain: **No**

> Every reservation created by a conductor can eventually be released.

**Caller side** — `RequestConductor.sol:38,49` — reservations are released only through the same conductor's `_consume`.

**Callee side** — `Turnstile.sol:76` — `setHubWarehouseConductor` replaces the conductor reached by withdrawals; the old conductor's `requestEffectiveAtEpoch` state is not migrated, and the Depot has no owner-side release.

**If violated** — Users' reserved funds stay unspendable after a conductor swap (requires admin intervention).

---

#### X-5

On-chain: **No**

> The epoch a solver builds a batch for is still current when `settle` lands.

**Caller side** — `SpotSwapConductor.sol:49`, `DelayedSettlementSwapConductor.sol:131` — revert `BadEpoch` if `settlementEpoch` moved.

**Callee side** — `Depot.sol:163-166` — any CONDUCTOR-role holder at any time, or anyone after 24h idle, can advance the epoch.

**If violated** — In-flight settles revert (liveness over batch stability, by design).

---

#### X-6

On-chain: **No**

> A collateralized party can always repay before its escrow deadline.

**Caller side** — `DelayedSettlementSwapConductor.sol:65,73` — repay requires `block.timestamp ≤ escrowDeadline` and a successful `Depot.transferFrom`.

**Callee side** — `Depot.sol:43` (`pause`, PAUSER, instant) makes `transferFrom` revert (`whenNotPaused` `:67`); the deadline is never extended and `unpause` is a separate role.

**If violated** — A pause spanning the deadline turns a willing repayer into a defaulter; reclaim later sends its collateral to `PENALTY_RECIPIENT_ACCOUNT_ID`.

---

#### X-7

On-chain: **Yes**

> Every Turnstile call into a ConductorGatedByTurnstile contract carries the 32-byte account+flags suffix.

**Caller side** — `Turnstile.sol:387,502,538` — all conductor calldata built via `_buildTurnstileCallData` (`:613-624`).

**Callee side** — `ConductorGatedByTurnstile.sol:25-42` — `_appended` reads the last 32 bytes whenever `msg.sender == TURNSTILE`.

**If violated** — Trailing arguments misread as the sender (identity spoofing).

---

#### X-8

On-chain: **No**

> The frozen-sender check on deposits uses a bridge-authenticated sender account.

**Caller side** — `Turnstile.sol:349-357` — source builds `fromAccountId` from `block.chainid` and puts it in the message body.

**Callee side** — `HubWarehouseConductor.sol:61-62` — freeze check and frozen-path mint use the body's `fromAccountId`, while the asset chain uses the bridge-reported `sourceChainId`.

**If violated** — Only under peer/bridge compromise: chain half of the sender is peer-asserted.

---

## 4. Economic Invariants

---

#### E-1

On-chain: **No**

> For each asset, Depot supply ≤ tokens held by that asset chain's VAULT.

**Follows from** — `I-1` + `I-2` + `X-1` + `X-2`

**If violated** — Withdrawals of that asset become a bank run; last withdrawers unpaid.

---

#### E-2

On-chain: **Yes**

> The solver cannot extract value from users beyond price improvement: each fill meets its limit and batches net to zero.

**Follows from** — `I-2` + `I-9` (+ guards `G-24`, `G-35`)

**If violated** — Solver profits at users' expense or mints unbacked fees.

---

#### E-3

On-chain: **No**

> Users can always exit without relying on the operator.

**Follows from** — `I-6` + `I-7` + `X-4` + `X-6` (and `I-8`: Failed messages need ADMIN `retry`, which sits behind a 48h delay in the reference wiring)

**If violated** — Funds stuck until admin action (conductor swap, failed message) or collateral lost (pause across a DS deadline).
