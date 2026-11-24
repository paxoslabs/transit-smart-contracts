# X-Ray Report

> Transit Contracts | 1480 nSLOC | 81b4e5f (`carson/tests`) | Foundry | 24/11/26

---

## 1. Protocol Overview

**What it does:** Hub-and-spoke cross-chain ledger: tokens are held in per-chain VAULTs, balances live in a hub `Depot`, and a solver settles user-signed swap orders against that ledger in epoch batches.

- **Users**: Deposit on any chain, trade on the hub ledger (spot or delayed/collateralized settlement), transfer between ledger accounts, withdraw to any asset chain. EOAs sign; contract wallets pre-approve or act via messages.
- **Core flow**: `Turnstile.dispatch/facilitate` → (CCIP if cross-chain) → hub `Turnstile` → conductor → `Depot` mint/burn/move.
- **Key mechanism**: Internal ledger keyed by `bytes28 (chainId << 160 | address)` for both accounts and assets; epoch-gated reservations/requests/cancellations so a user cannot invalidate an in-flight solver batch; limit-price-only settlement guarantee.
- **Token model**: No protocol token. Whitelisted ERC20s (e.g. USDC, USDG) per chain; the same token on two chains is two distinct Depot assets.
- **Admin model**: OZ AccessManager per chain. Reference wiring (`test/integration/SharedSetup.sol`; no deploy scripts yet): ADMIN multisig with 48h execution delay, PAUSER EOA (pause only), multisig UNPAUSER (instant), SOLVER EOA, Predicate FREEZE_MANAGER.

For a visual overview of the protocol's architecture, see the [architecture diagram](architecture.svg).

### Contracts in Scope

| Subsystem | Key Contracts | nSLOC | Role |
|-----------|--------------|------:|------|
| Ledger | Depot, AddressFreezeList | 204 | Balances, reservations, epoch clock, compliance freeze |
| Entrypoint / custody | Turnstile | 483 | Per-chain dispatch/facilitate, VAULT custody, message routing, replay + retry |
| Messaging | MessagingAdapter, CCIPMessagingAdapter | 182 | Peer config and CCIP send/receive |
| Conductors | HubWarehouseConductor, UserConductor, RequestConductor, SpotSwapConductor, DelayedSettlementSwapConductor, SwapConductor, ConductorGatedByTurnstile | 563 | Deposits/withdrawals, transfers, request/reserve lifecycle, spot and escrowed swaps, sender suffix |
| Helpers | TransitAddressLib, Typehashes, Roles | 48 | bytes28 encoding, EIP-712 typehashes, role ids |

### How It Fits Together

The core trick: every cross-chain or facilitated call is reduced to "Turnstile calls a hub conductor with a 32-byte `(account, flags)` calldata suffix", and the conductor uses that suffix as the actor's identity against a single permanent ledger.

### Deposit (spoke → hub)

```
User → Turnstile(spoke).dispatch(Deposit)
  ├─ safeTransferFrom(user → VAULT, amount)          *custody taken on source chain*
  └─ _handleMessage → CCIPMessagingAdapter.send → Router.ccipSend
CCIP Router → CCIPMessagingAdapter(hub).ccipReceive   *peer + allowFrom checked in _receive*
  └─ Turnstile(hub).handleReceivedMessage → _executeMessageLocally
       └─ HubWarehouseConductor.receiveDeposit(sourceChainId from bridge, ...)
            ├─ frozen sender → Depot.mint(sender) and stop
            ├─ Depot.mint(toAccountId, (sourceChainId, asset), amount)
            └─ fee? Depot.transferFrom(to → feeReceiver)   *failure → message Failed, ADMIN retry*
```

### Withdrawal (hub ledger → asset chain)

```
Owner → HubWarehouseConductor.requestWithdrawal (direct, or Generic from owner's chain)
  └─ Depot.reserve                                    *effective at settlementEpoch+1*
Anyone → Turnstile(hub).dispatch(Withdrawal)          *or solver facilitate: instant for hub-account signer*
  └─ HubWarehouseConductor.executeWithdrawal          *consume: release reservation, EXECUTED*
       └─ Depot.burn(min(amount, free) or 0)
  └─ amount>0: WithdrawalMessage → local VAULT.transferFrom, or send → spoke Turnstile → VAULT.transferFrom
     amount==0: no message; bridgeFee refunded to msg.sender
```

### Generic call (any chain → hub conductor)

```
User → Turnstile.dispatch(Generic{target, data})
  └─ GenericMessage{sender,target,data,deadline,salt} → hub
Turnstile(hub)._executeMessageLocally
  ├─ deadline / _isRoutable(target, selector)         *whitelist && !TURNSTILE-role && !VAULT allowance*
  └─ target.call(data ++ (sourceChainId, sender) ++ facilitatedFlag)
       └─ ConductorGatedByTurnstile._senderAccountId reads the suffix
```

### Spot settlement

```
Solver → SpotSwapConductor.settle(epoch, OrderFill[], Fee[])
  ├─ epoch == Depot.settlementEpoch
  ├─ per fill: expiry, fill-or-kill, signature | preApproved, _recordFill (Overfill, Cancelled), limit price
  ├─ deltas: credits [0..n), debits [n..2n), fee mints [2n..)     *credits first*
  ├─ Depot.transferAmong                              *per-asset zero-sum, per-debit free balance*
  └─ Depot.advanceEpoch
```

### Delayed (escrowed) settlement

```
Solver → DelayedSettlementSwapConductor.settle(epoch, orders, sigs, PairedFill[])
  ├─ per pair: escrow legs; collateralized side posts amount/100 and owes amount
  ├─ Depot.transferAmong(owners → conductor account)
  └─ pairs with no collateralized side → _release immediately
Leg owner → repay (≤ deadline)  → release when both debts 0
Anyone   → reclaim (> deadline)  → refunds; unpaid collateral → PENALTY_RECIPIENT
```

---

## 2. Threat & Trust Model

### Protocol Threat Profile

> Protocol classified as: **Bridge** with **DEX (batch/RFQ settlement)** characteristics

Lock-in-VAULT / mint-on-hub / burn-on-hub / release-on-spoke with message replay keys and peer authentication is the dominant pattern; settlement is solver-matched signed orders (no AMM curve) over an internal ledger.

### Actors & Adversary Model

| Actor | Trust Level | Capabilities |
|-------|-------------|-------------|
| ADMIN (multisig) | Trusted | Every unmapped `restricted` fn behind 48h schedule (reference wiring): `forceTransferFrom` (any balance, bypasses pause/freeze/reservations), `setRoutable`, `setPeer`, `setHubWarehouseConductor`, `retry`, role grants. |
| SOLVER | Bounded (needs user signature/pre-approval; limit price, zero-sum, overfill enforced) | `facilitate` (chooses which signed actions, order, timing), `settle` on both swap conductors (fill amounts, fees, batch composition). Not pausable at conductor level; blocked when Depot/Turnstile paused. |
| PAUSER (EOA) | Bounded (pause only) | Instant `pause` of Depot and Turnstile; cannot unpause. |
| UNPAUSER (multisig) | Trusted | Instant `unpause`. |
| FREEZE_MANAGER (Predicate) | Bounded (freeze list only) | Instant freeze/unfreeze by address (all chains at once). |
| CCIP router + peer adapters | Trusted | Deliver authenticated messages; a forged Deposit mints, a forged Withdrawal releases VAULT funds. |
| CONDUCTOR contracts | Trusted code | All Depot primitives and early `advanceEpoch`. |

**Adversary Ranking** (bridge-primary, adjusted by git evidence):

1. **Compromised admin / bridge peer** — controls minting authority (peers, conductors, routing) and the VAULT-approved Turnstile's whitelist.
2. **Malicious or misbehaving solver** — chooses batch composition and timing against users' epoch-gated requests and cancels.
3. **Message replay / fake message crafter** — targets digest-based replay keys, retry, and suffix-based identity.
4. **Finality/reorg exploiter** — CCIP Fast Confirmation Rule is used for all messages.
5. **Griefing user / third party** — permissionless execution of others' effective requests and public epoch advance.

See [entry-points.md](entry-points.md) for the full permissionless entry point map.

### Trust Boundaries

- **ADMIN** — 48h AccessManager delay on every admin fn in the reference wiring, but unmapped `restricted` fns fail-open to ADMIN; worst action `Depot.forceTransferFrom:150` (no event distinct from Transfer). *Git signal: AccessManager migration landed 2026-11-19 (38ae40b, 214 lines).*
- **Bridge / peers** — `MessagingAdapter._receive:139-140` trusts `peers[chainId]`; source chain from `chainIdForRemoteId`; Deposit body still carries `fromAccountId` chain.
- **Turnstile → conductors** — identity is the calldata suffix (`ConductorGatedByTurnstile:25-42`); any Turnstile call path without `_buildTurnstileCallData` would misattribute senders.
- **Generic whitelist** — hub Turnstile holds unlimited VAULT approvals; safety relies on `_isRoutable:583-587` at execution. *Git signal: 3 consecutive redesigns of this guard (§104 in docs/Edits.md, 6f89807).*
- **Solver** — bounded by signatures, `LimitPrice`, `Overfill`, `NotZeroSum`; unbounded in ordering/selection and in the timing of facilitated (immediate) cancels/withdrawals.

### Key Attack Surfaces

- **Generic message routing through a VAULT-approved Turnstile** &nbsp;&#91;[I-16](invariants.md#i-16), [X-7](invariants.md#x-7), [G-38](invariants.md#g-38), [G-39](invariants.md#g-39)&#93; — `Turnstile._isRoutable:583`, `_hasVaultAllowance:597-611` (assembly staticcall, any-gas), `setRoutable:80-93`; worth checking targets whose `allowance()` lies or reverts, proxies to tokens, fallback-selector collisions, and selectors remapped after whitelisting.

- **Message lifecycle, failure split and retry** &nbsp;&#91;[I-8](invariants.md#i-8), [G-41](invariants.md#g-41), [G-45](invariants.md#g-45)&#93; — `Turnstile._handleMessage:434-460`, `_executeMessageLocally:483-569`, `retry:250-258`; worth tracing status transitions across same-chain revert, OOG heuristic `gasleft() <= gasBefore/63` at `:563`, and retry re-handling with the original source chain.

- **Admin operational powers and default-to-admin mapping** &nbsp;&#91;[I-3](invariants.md#i-3), [X-4](invariants.md#x-4)&#93; — `Depot.forceTransferFrom:150`, `Turnstile.setHubWarehouseConductor:72`, `setRoutable:80`, `MessagingAdapter.setPeer:46`; worth confirming which effects survive a conductor/adapter swap (orphaned requests and reservations) and what an unmapped selector defaults to.

- **Third-party consumption of effective requests** &nbsp;&#91;[I-7](invariants.md#i-7), [X-3](invariants.md#x-3)&#93; — `UserConductor.executeTransfer:33-50` and Withdrawal dispatch are callable by anyone once effective; `_executableAmount:53-66` returns 0 for short non-partially-fillable requests yet `_consume:43-51` marks them EXECUTED; worth checking who can force a request to execute at a moment of low free balance.

- **Pause interaction with time-boxed obligations** &nbsp;&#91;[X-6](invariants.md#x-6), [I-11](invariants.md#i-11)&#93; — `Depot.pause:43` (PAUSER EOA, instant) blocks `DelayedSettlementSwapConductor.repay:64-79` while `escrowDeadline` keeps running; worth tracing the outcome of a pause that spans a deadline, and similarly request/withdrawal deadlines.

- **Epoch clock control** &nbsp;&#91;[X-5](invariants.md#x-5), [I-6](invariants.md#i-6), [I-10](invariants.md#i-10)&#93; — `Depot.advanceEpoch:163` is callable by any CONDUCTOR anytime and by anyone after 24h; cancels/requests/expiry key off `settlementEpoch`/`lastEpochAdvancedAt`; worth checking ordering between public advance, in-flight `settle`, and order `expiresAt <= lastEpochAdvancedAt`.

- **SpotSwap batch construction** &nbsp;&#91;[I-2](invariants.md#i-2), [G-7](invariants.md#g-7), [G-24](invariants.md#g-24), [G-27](invariants.md#g-27)&#93; — `SpotSwapConductor.settle:48-66` / `_fillOrders:70-109` (credits-before-debits layout), `Depot.transferAmong:79-132`; worth checking same-order multi-fill, same-batch spend-what-you-receive, and fee mints vs surplus.

- **Delayed-settlement escrow accounting** &nbsp;&#91;[I-12](invariants.md#i-12), [I-13](invariants.md#i-13), [G-34](invariants.md#g-34), [G-35](invariants.md#g-35), [G-36](invariants.md#g-36)&#93; — `DelayedSettlementSwapConductor.settle:122-168`, `_escrowLeg:229-270`, `_release:296-327` / `_releaseLeg:308`, `_reclaim:89-118`; worth checking multiple PairedFills per order, fee/limit arithmetic per leg, `filledAmount` after reclaim, and reclaim on dead escrow ids.

- **Peer configuration consistency** &nbsp;&#91;[I-15](invariants.md#i-15), [G-46](invariants.md#g-46)&#93; — `MessagingAdapter.setPeer:46-67` / `removePeer:69-73` maintain `peers` and `chainIdForRemoteId` separately; worth checking remoteId changes and reuse across chains.

- **Custody-to-mint amount and finality** &nbsp;&#91;[X-1](invariants.md#x-1), [E-1](invariants.md#e-1)&#93; — `Turnstile._dispatchDeposit:348` vs `HubWarehouseConductor.receiveDeposit:65`; `CCIPMessagingAdapter._buildMessage:70-86` (FCR); worth confirming asset behaviour assumptions and reorg exposure per lane.

- **Account identity across chains** &nbsp;&#91;[X-8](invariants.md#x-8), [G-43](invariants.md#g-43)&#93; — facilitated signers act as `(hub, signer)` (`Turnstile._dispatchWithdraw:378-379`), Generic sender chain from bridge (`:538-540`), Deposit `fromAccountId` from body (`HubWarehouseConductor:61`); worth tracing every place a caller can choose the chain half of an account.

### Protocol-Type Concerns

**As a Bridge:**
- `Turnstile.digestMessage:186` keys replay on `(sourceChainId, actionType, body)`; Withdrawal salt is `hashWithdrawalAction` (owner-bound) — worth confirming no two distinct actions produce identical bodies, especially Deposit/Generic with user-chosen salts.
- `Turnstile.handleReceivedMessage:264` passes `messageGas = 0`/`bridgeFee = 0` into `_handleMessage`; inbound always executes locally — worth confirming a spoke can never receive a Deposit/Generic (no `hubWarehouseConductor` → `NoHandler` revert → bridge retry loop).

**As a batch-settlement DEX:**
- `SpotSwapConductor:90` uses `fullMulDivUp` for the limit (rounds in the user's favour); DS limit at `:246-250` subtracts the counterparty fee first — worth checking rounding and fee > amount (checked-arithmetic panic) on both legs.

### Temporal Risk Profile

**Deployment & Initialization:**
- No deploy scripts; all role wiring (≈30 `setTargetFunctionRole`/`grantRole` calls) lives only in `test/integration/SharedSetup.sol`; unmapped functions default to ADMIN and the deployer holds ADMIN with 0 delay until `_handOffAdmin`.
- `Turnstile` constructor cannot set the adapter (circular immutable `LOCAL_TURNSTILE`); calls revert until `setMessagingAdapter`, and `setHubWarehouseConductor:74` requires the adapter first.

**Market Stress:**
- Delayed settlement collateral is 1% (`FILL_RATIO = 100`) with a ≤1 day window; defaulting is an accepted free option for stablecoin pairs (per docs/PreAudit.md KI-9).

### Composability & Dependency Risks

**Dependency Risk Map:**

> **Chainlink CCIP Router** — via `CCIPMessagingAdapter._send/_quote`, `CCIPReceiver.ccipReceive`
> - Assumes: authentic sender/selector; delivers each message once; GenericExtraArgsV3 FCR lanes enabled
> - Validates: `onlyRouter`; peer + `allowMessagesFrom` in `_receive`
> - Mutability: Router address immutable per adapter; CCIP lanes governed by Chainlink
> - On failure: receive revert → CCIP manual re-execution; send revert → user tx reverts

> **OpenZeppelin AccessManager** — via `AccessManaged.restricted` on every admin/role fn, `Turnstile._isTurnstileOnly`
> - Assumes: role mapping matches intended wiring
> - Validates: n/a
> - Mutability: Governed by ADMIN (48h delay in reference wiring)
> - On failure: revert

> **Whitelisted ERC20s** — via `SafeTransferLib.safeTransferFrom` (deposit), `trySafeTransferFrom` (release), EIP-2612 `permit`
> - Assumes: exact transfer amounts, no hooks, no rebasing
> - Validates: asset whitelist only; no balance-diff check
> - Mutability: Token-specific (e.g. USDC upgradeable, blacklistable)
> - On failure: deposit reverts; release → Failed message (cross-chain) or revert (same-chain)

**Token Assumptions** *(unvalidated only)*:
- Fee-on-transfer / rebasing: assumes `amount` arrives in VAULT — impact: Depot supply above custody for that asset.
- Blacklisting (USDC/USDT): VAULT or recipient blacklisted makes releases fail → Failed messages needing admin `retry`.

---

## 3. Invariants

> ### 📋 Full invariant map: **[invariants.md](invariants.md)**
>
> A dedicated reference file contains the complete invariant analysis — do not look here for the catalog.
>
> - **46 Enforced Guards** (`G-1` … `G-46`) — per-call preconditions with `Check` / `Location` / `Purpose`
> - **17 Single-Contract Invariants** (`I-1` … `I-17`) — Conservation, Bound, Ratio, StateMachine, Temporal
> - **8 Cross-Contract Invariants** (`X-1` … `X-8`) — caller/callee pairs that cross scope boundaries
> - **3 Economic Invariants** (`E-1` … `E-3`) — higher-order properties deriving from `I-N` + `X-N`
>
> Every inferred block cites a concrete Δ-pair, guard-lift + write-sites, state edge, temporal predicate, or NatSpec quote. The **On-chain=No** blocks are the high-signal ones — each is simultaneously an invariant and a potential bug. Attack-surface bullets above cross-link directly into the relevant blocks (e.g. `[X-6]`, `[I-15]`).

---

## 4. Documentation Quality

| Aspect | Status | Notes |
|--------|--------|-------|
| README | Present | `README.md` (Foundry template) |
| NatSpec | Thorough | Every concrete contract has an interface in `src/interfaces/` carrying NatSpec; `@inheritdoc` in implementations; `@dev` on internals |
| Spec/Whitepaper | Present | `KDDs.md` (design decisions; partly stale per `docs/PreAudit.md` §9), `docs/PreAudit.md` (AI-oriented trust model, invariants, known issues), `docs/Edits.md` (edit log) |
| Inline Comments | Adequate | Rationale comments on non-obvious paths (zero-withdrawal refund, credits-first layout, setRoutable guards, FCR) |

---

## 5. Test Analysis

| Metric | Value | Source |
|--------|-------|--------|
| Test files | 15 (incl. helpers/mocks/setup) | File scan |
| Test functions | 76 (71 unit/integration, 1 stateless fuzz, 4 invariant) | File scan (enumerate.sh counted 0: its `grep -P` is unsupported on macOS) |
| Line coverage | 86.6% (`src/` only, 564/651) | `forge coverage --ir-minimum` |
| Branch coverage | 53.2% (`src/` only, 83/156) | `forge coverage --ir-minimum` |

### Test Depth

| Category | Count | Contracts Covered |
|----------|-------|-------------------|
| Unit | 33 | Depot, HubWarehouseConductor, Turnstile (custody, whitelist guards, dependencies) |
| Integration | 38 | Turnstile hub/spoke paths, SpotSwap batch, DelayedSettlement lifecycle, retry, facilitation fees (one-EVM multichain via `vm.chainId`, mocked CCIP router) |
| Stateless Fuzz | 1 | Full lifecycle (deposit → transfer → 1-to-N fill → withdraw) with backing check |
| Stateful Fuzz (Foundry) | 4 | Depot reservations (`test/invariant/ReservationInvariant.t.sol`) |
| Stateful Fuzz (Echidna/Medusa) | 0 | none |
| Formal Verification | 0 | none |
| Fork | 0 | none (old fork-based suite removed) |

### Gaps

- No stateful fuzzing of Turnstile message lifecycle or swap settlement (only reservations).
- Branch coverage low in `MessagingAdapter` (0/9), `SpotSwapConductor` (1/5), `UserConductor` (0/2), `AddressFreezeList` (0/2): revert paths largely untested (`NotZeroSum`, `LimitPrice`, `Overfill`, peer errors).
- No real CCIP router/fork test; OOG heuristic untested.
- No formal verification of ledger conservation or reservation math.

---

## 6. Developer & Git History

> Repo shape: normal_dev — 265 source-touching commits over 63 days (2026-09-21 → 2026-11-23). Analyzed branch: `carson/tests` at `81b4e5f`.

### Contributors

| Author | Commits | Source Lines (+/-) | % of Source Changes |
|--------|--------:|--------------------|--------------------:|
| Nick Barry | 201 | +7377 / -5469 | 65.7% |
| CarsonCase (+ "Carson Case") | 89 | +3857 / -1993 | 34.3% |

### Review & Process Signals

| Signal | Value | Assessment |
|--------|-------|------------|
| Unique contributors | 2 (3 author names) | Small team |
| Merge commits | 9 of 290 (3.1%) | Some PR merges; most work direct/branch commits |
| Repo age | 2026-09-21 → 2026-11-23 | ~2 months |
| Recent source activity (30d) | 172 commits | Late burst: ~65% of source commits in the last 30 days |
| Test co-change rate | 46.8% | File co-modification, not coverage |

### File Hotspots

| File | Modifications | Note |
|------|-------------:|------|
| src/depot/Depot.sol | 93 (with renames) | Ledger core; reservation packing changed 2026-11-19 |
| src/turnstile/Turnstile.sol | 92 (with renames) | Entrypoint; whitelist guards and AccessManager switch late |
| src/conductor/DelayedSettlementSwapConductor.sol | 70 | Escrow math; several fix/revert commits |
| src/conductor/SpotSwapConductor.sol | 52 | Delta layout merged 2026-11-21 |
| src/conductor/HubWarehouseConductor.sol | 49 | Deposit fee + withdrawal execution |

### Security-Relevant Commits

**Score** = weighted sum of fix-like signals; **10+ warrants a manual diff.**

| SHA | Date | Subject | Score | Key Signal |
|-----|------|---------|------:|------------|
| 74ebd0b | 2026-11-16 | permit2 removed; regular permit with front-run check | 19 | signatures + token transfer logic |
| 73765f9 | 2026-10-27 | remove reentrancy guard | 14 | loosens guards (-10) |
| d46302a | 2026-11-18 | custom error for underflow on Depot `_release` | 13 | fund flows, no test change |
| 1b1fa8f | 2026-11-10 | block deposits to different address to avoid freeze bypass | 13 | bug fix with tests |
| a4b4ba5 | 2026-11-17 | file not included in last commit (DS) | 12 | DS logic, no test change |
| f6dc3ec | 2026-11-10 | Revert "allow partial delayed settlement" | 12 | DS token transfer logic |
| 6894a86 | 2026-11-07 | proportional penalty for nonpayment of DS debt | 12 | DS fund flows, no test change |
| c99dcf3 | 2026-10-01 | combine deposit and bridge flows | 12 | removes runtime guard |

### Dangerous Area Evolution

| Security Area | Commits | Key Files |
|--------------|--------:|-----------|
| fund_flows | 118 | DelayedSettlementSwapConductor, HubWarehouseConductor, Depot |
| signatures | 101 | DelayedSettlementSwapConductor, SpotSwapConductor, SwapConductor |
| state_machines | 90 | AddressFreezeList, HubWarehouseConductor, Depot |
| oracle_price (limit-price math) | 37 | DelayedSettlementSwapConductor, SpotSwapConductor |

### Security Observations

- **Late, large refactors** — AccessManager replaced TransitAuthority + DepotTimelock (38ae40b, 2026-11-19); whitelist guards (6f89807) and reservation packing (9c93eba) the same day.
- **Fix-without-test rate 80%** — most fix-scored commits touch no test file (co-modification metric).
- **Reentrancy guard removed** (73765f9) — rationale recorded in KDDs.md #4 (Depot has no callbacks; tokens whitelisted).
- **DS conductor churn** — 70 modifications including a reverted partial-settlement feature (f6dc3ec) and penalty changes (6894a86).
- **Two-developer concentration** — Nick Barry 65.7% / CarsonCase 34.3% of source additions.
- **No TODO/FIXME markers** in `src/` (tech-debt scan 0).

### Cross-Reference Synthesis

- **Turnstile is #1 in churn and in attack-surface count** — routing, retry, identity and custody surfaces all converge in `_executeMessageLocally` → highest-leverage review.
- **AccessManager migration + 48h ADMIN delay ↔ E-3** — `retry` is unmapped (ADMIN), so every Failed cross-chain message now waits ≥48h; the migration is 5 days old.
- **DS churn ↔ X-6 / I-12 / I-13** — escrow math with repeated fix/revert history and a pause-vs-deadline gap.

---

## X-Ray Verdict

**HARDENED** — Unit, integration, stateless fuzz and stateful invariant tests exist; NatSpec plus design/pre-audit docs are present; roles are explicit with a 48h admin delay and an emergency pause.

**Structural facts:**
1. 1480 nSLOC in 15 in-scope files across 5 subsystems; 46 entry points (11 permissionless).
2. 76 test functions; 86.6% line / 53.2% branch coverage on `src/`.
3. 2 developers; 172 of 265 source commits in the final 30 days.
4. No upgradeable proxies; access control is a stock OZ AccessManager whose wiring exists only in test setup.
5. No reentrancy guards anywhere; one internal ledger with no external price oracle.
