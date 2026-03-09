# Pacta Core Protocol v4 — Architecture & Integration Guide

## Overview

Pacta is **the settlement layer of Sui**. It is infrastructure — a primitive that other protocols build on, not an application end-users interact with directly. The closest analogue is DeepBook: a core protocol that provides settlement guarantees, composable primitives, and a shared object model that any protocol can integrate with.

Pacta enables:
- **Condition-based escrow** — assets released only when a configurable bitmask of conditions is satisfied
- **Asset-agnostic settlement** — coins, NFTs, and arbitrary Sui objects in the same agreement
- **Fully on-chain agreements** — all state, custody, and routing on-chain; no off-chain reliance
- **Shared object model** — agreements are shareable, composable, and wrappable
- **No protocol token** — trustless by design; no governance required for settlement

---

## Changelog

| Version | Changes |
|---------|---------|
| **v4** (current) | `arbiter_settle()`, `arbiter_cancel()`, `record_outcome()`, `extract_hook_with_receipt()`, `registry_recorded` field, timelock upgrade module |
| v3 | `SettlementReceipt` hot potato, generic hook system (`attach_hook`/`extract_hook`), `mutual_cancel()`, `conclude_dispute()`, `cancel_expired()` |
| v2 | Non-generic `Agreement`, dynamic field escrow, condition bitmask engine, dispute system |
| v1 | Generic `Agreement<T>`, single coin type, manual `mark_complete()` |

---

## Deployed Addresses

### Testnet

| Object | ID |
|--------|-----|
| Package | `0xc69e192b8cc1ace8b785c467970542a2dba7a5c2e21dcde55ad668af997d086f` |
| PactaRegistry (shared) | `0xd53ca2b8b780b5b9c30417a83296f00f90ac21a9a8a29463ccfae1829d0af2b5` |
| AdminCap | `0xee29a1a0fdfc40309dbe7ea1aecef11b03b430a4ac832304c55578b815ddd193` |
| UpgradeCap | `0x5191434a9bebf21b7157109d7b57cddc1e86fbccc35f77a064ff8ea9b10082a2` |

### Mainnet

| Object | ID |
|--------|-----|
| Package | — (not yet deployed) |
| PactaRegistry (shared) | — |
| AdminCap | — |
| UpgradeCap | — |

---

## Architecture Diagram

```
┌────────────────────────────────────────────────────────────────────┐
│                       APPLICATION LAYER                            │
│                                                                    │
│  NFT marketplace · OTC desk · P2P exchange · DAO payroll          │
│  Lending protocol · AI agent settlement · Cross-chain bridge      │
└─────────────────────────────┬──────────────────────────────────────┘
                              │ calls
┌─────────────────────────────▼──────────────────────────────────────┐
│                    PACTA CORE PROTOCOL (v4)                        │
│                                                                    │
│  Agreement (non-generic, asset-agnostic, key + store)             │
│  ┌──────────────────────────────────────────────────────────┐     │
│  │  State machine: CREATED → ACTIVE → SETTLED/CANCELLED     │     │
│  │  Assets: dynamic fields (CoinEscrow<T>, ObjectEscrow)    │     │
│  │  Hook: dof slot for protocol-bound execution context     │     │
│  └──────────────────────────────────────────────────────────┘     │
│                                                                    │
│  Condition Engine: release_conditions bitmask → auto-settlement   │
│  Composability:    SettlementReceipt hot potato → atomic callback │
│  Executor System:  permissionless settle() / cancel_expired()     │
│  Arbiter System:   arbiter_settle() / arbiter_cancel()            │
│  Registry:         record_outcome() permissionless stat tracking  │
└─────────────────────────────┬──────────────────────────────────────┘
                              │ emits
┌─────────────────────────────▼──────────────────────────────────────┐
│                         EVENT LAYER                                │
│                                                                    │
│  AgreementCreated · CoinDeposited · ObjectDeposited               │
│  PartyApproved · AgreementSettled · AgreementCancelled            │
│  MutualCancelConsent · CoinClaimed · ObjectClaimed                │
│  DisputeRaised · DisputeResolved · HookAttached                   │
└────────────────────────────────────────────────────────────────────┘
```

---

## Project Structure

```
pacta-core-protocol/
├── Move.toml
├── ARCHITECTURE.md
├── GOVERNANCE.md           # Multisig + timelock upgrade ops guide
├── sources/
│   ├── pacta.move          # Core settlement protocol (~1450 lines)
│   └── timelock.move       # 14-day upgrade timelock module
├── tests/
│   ├── pacta_tests.move
│   └── timelock_tests.move
├── sdk/                    # TypeScript SDK for builders
│   └── src/
│       ├── client.ts
│       ├── transactions.ts
│       ├── types.ts
│       └── index.ts
└── docs/                   # Mintlify documentation site
```

---

## Core Data Structure

```move
public struct Agreement has key, store {
    id: UID,
    version: u64,                 // Protocol version (currently 4)
    creator: address,             // Who created the agreement (may be a contract)
    party_a: address,             // First party
    party_b: address,             // Second party (@0x0 = open; set via set_party_b())
    arbiter: address,             // Dispute resolver (@0x0 = none)
    state: u8,                    // Lifecycle state (see State Machine below)
    release_conditions: u8,       // Bitmask: which conditions must be met to auto-settle
    a_deposited: bool,            // Party A has made at least one deposit
    b_deposited: bool,            // Party B has made at least one deposit
    a_approved: bool,             // Party A has called approve()
    b_approved: bool,             // Party B has called approve()
    a_cancel_consent: bool,       // Party A has called mutual_cancel()
    b_cancel_consent: bool,       // Party B has called mutual_cancel()
    a_obj_count: u64,             // Monotonic object counter for party A deposits
    b_obj_count: u64,             // Monotonic object counter for party B deposits
    active_slots: u64,            // Live escrow entries (must reach 0 before destroy())
    hook_attached: bool,          // Whether a hook object is stored on this agreement
    a_recipient: address,         // Set at finalization: who claims party A's deposits
    b_recipient: address,         // Set at finalization: who claims party B's deposits
    registry_recorded: bool,      // True after record_outcome() called (prevents double-count)
    terms_hash: vector<u8>,       // Hash of off-chain terms (audit trail)
    expiry_ms: u64,               // Agreement deadline in ms (0 = none)
    unlock_time_ms: u64,          // Timelock on claims (0 = claims allowed immediately)
    created_at_ms: u64,
    settled_at_ms: u64,           // Set at finalization (0 = not yet finalized)
    metadata: vector<u8>,         // App-specific data
}
```

### Why Non-Generic?

`Agreement<T>` (v1) forced each agreement to one coin type. The v2+ approach stores assets as **dynamic fields**, so one agreement holds:
- SUI + USDC simultaneously (two `CoinEscrow<T>` fields)
- An NFT + SUI (one `ObjectEscrow` field + one `CoinEscrow<T>`)
- Multiple NFTs from both parties
- Any combination without any struct changes

### Why `has key, store`?

- `key` — on-chain object with UID, directly shareable or transferable
- `store` — can be **wrapped inside other protocols' structs**, enabling fully embedded agreements without sharing

---

## Dynamic Field Keys

```move
// Fungible token escrow: one slot per (party, coin type T).
// Same-party same-type deposits merge — unlimited top-ups, one active_slot.
public struct CoinEscrow<phantom T> has copy, drop, store { party: u8 }

// Object/NFT escrow: one slot per (party, sequential index).
// Each object gets its own slot regardless of type.
public struct ObjectEscrow has copy, drop, store { party: u8, index: u64 }

// Hook slot: one per agreement. Holds protocol-bound execution context.
public struct HookKey has copy, drop, store {}
```

---

## Condition-Based Settlement Engine

The settlement engine is the core innovation. No single party can release funds. Instead, each agreement defines a **bitmask of conditions** that must ALL be satisfied simultaneously.

### Condition Flags

| Flag | Bit | Value | Description |
|------|-----|-------|-------------|
| `COND_A_DEPOSITED` | 0 | 1 | Party A has made at least one deposit |
| `COND_B_DEPOSITED` | 1 | 2 | Party B has made at least one deposit |
| `COND_A_APPROVED`  | 2 | 4 | Party A has called `approve()` |
| `COND_B_APPROVED`  | 3 | 8 | Party B has called `approve()` |
| `COND_TIMELOCK`    | 4 | 16 | Current time ≥ `unlock_time_ms` |

### Common Presets

| Use Case | Bitmask | Value | Behavior |
|----------|---------|-------|----------|
| Atomic swap | `A_DEP \| B_DEP` | 3 | Auto-settles when both deposit |
| Freelance escrow | `A_DEP \| A_APPROVED` | 5 | Client deposits, releases when satisfied |
| Mutual sign-off | `A_APR \| B_APR` | 12 | Both must explicitly approve |
| Vesting | `A_DEP \| TIMELOCK` | 17 | Deposit now, release after unlock time |
| Timed swap | `A_DEP \| B_DEP \| TIMELOCK` | 19 | Both deposit, settle after timelock |
| Arbiter-only | `0` | 0 | No auto-settle; arbiter controls outcome |
| Full escrow | `A_DEP \| B_DEP \| A_APR` | 7 | Both deposit, client confirms delivery |

### How the Engine Works

```
release_conditions = COND_A_DEPOSITED | COND_B_DEPOSITED  (= 3)

1. Party A deposits 100 USDC
   a_deposited = true
   check: (met & required) == required? → (1 & 3) == 3? → 1 ≠ 3 → wait

2. Party B deposits an NFT
   b_deposited = true
   check: (3 & 3) == 3? → YES → AUTO-SETTLE fires inside deposit_coin()
   a_recipient = party_b  (cross-delivery)
   b_recipient = party_a

3. Party B claims A's 100 USDC via claim_coin()
4. Party A claims B's NFT via claim_object()
```

No party called `mark_complete`. No admin key was used. The **conditions themselves** enforced the settlement.

---

## Agreement Lifecycle (State Machine)

```
                       ┌──────────┐
                       │ CREATED  │ ← create_agreement()
                       └─────┬────┘
                             │ first deposit_coin() / deposit_object()
                       ┌─────▼────┐
          ┌────────────│  ACTIVE  │────────────────┐
          │            └──┬───┬───┘                │
          │               │   │                    │
     cancel()        auto  raise_dispute()     expire +
   (one party         or    (party req.        cancel_expired()
    deposited)       settle  arbiter)
          │            │   │                    │
    ┌─────▼────┐  ┌────▼─┐ ┌▼──────────┐  ┌────▼──────┐
    │CANCELLED │  │SETTLED│ │ DISPUTED  │  │CANCELLED  │
    └─────┬────┘  └───┬───┘ └──┬────┬──┘  └─────┬─────┘
          │           │        │    │             │
     claim()     claim()  resolve() split/     claim()
   (self-refund) (cross-  (winner)  assign()  (self-refund)
                 delivery)  │        │
                        ┌───▼──┐  ┌──▼──────────────┐
                        │SETTLE│  │ DISPUTE_RESOLVED │
                        └──────┘  │ (immediate xfer) │
                                  └─────────────────┘
```

### Settlement Routing (set at finalization, immutable thereafter)

| Outcome | A's deposits → | B's deposits → |
|---------|----------------|----------------|
| **Settled** (auto or executor) | party_b | party_a |
| **Arbiter settle** | party_b | party_a |
| **Cancelled** (any path) | party_a | party_a |
| **Dispute → favor A** | party_a | party_a |
| **Dispute → favor B** | party_b | party_b |
| **Dispute → split coin** | immediate transfer | immediate transfer |

---

## Composability Primitives

### 1. SettlementReceipt — Hot Potato

```move
// Zero abilities — true hot potato.
// Returned by settle_with_receipt(). MUST be consumed in the same PTB.
public struct SettlementReceipt {
    agreement_id: ID,
    a_recipient: address,
    b_recipient: address,
    settled_at_ms: u64,
}
```

The receipt pattern enables **atomic settlement + callback** without trusted intermediaries. External protocols (DEXes, NFT marketplaces, lending) build a PTB that:
1. Calls `settle_with_receipt()` → get receipt
2. Calls their own `on_settlement(receipt, ...)` → process callback
3. Calls `consume_settlement_receipt(receipt)` → destroy receipt

If step 2 or 3 fails or is missing, the entire PTB aborts. Atomicity is enforced at the Move type system level, not by code logic.

### 2. Hook System — Agreement-Bound Context

```move
// Attach any key+store object to the agreement as execution context.
// One slot per agreement. Survives until explicitly extracted.
public fun attach_hook<H: key + store>(agreement, hook, ctx)

// Extract with authorization: caller must be party_a, party_b, or creator.
public fun extract_hook<H: key + store>(agreement, ctx): H

// Extract using a SettlementReceipt as authorization proof.
// Receipt proves settlement happened. Executor holds the receipt; no party auth needed.
// Call BEFORE consume_settlement_receipt() — takes receipt by reference.
public fun extract_hook_with_receipt<H: key + store>(agreement, &receipt): H
```

Protocols store their execution context (routing info, listing IDs, order IDs) on the agreement. After settlement, the hook is extracted and used to trigger follow-up logic.

### 3. Executor System — Permissionless Settlement Trigger

```move
// Any address can call settle() or cancel_expired() once conditions are met.
// Executors cannot redirect funds — they only advance the state machine.
// The executor address is recorded in AgreementSettled for attribution.
entry fun settle(agreement, clock, ctx)
public fun cancel_expired(agreement, clock, ctx)
```

Bots, AI agents, or any on-chain automation can trigger settlement. This is essential for:
- Timelock-based agreements (no party action triggers the final check)
- Headless/automated settlement pipelines
- Keeper networks that earn gas refunds or rewards off-protocol

---

## Security Model

### Access Control Matrix

| Function | Who Can Call | Conditions |
|----------|-------------|-----------|
| `create_agreement` | Anyone | — |
| `deposit_coin/object` | party_a, party_b | STATE_CREATED or ACTIVE, not expired |
| `approve` | party_a, party_b | STATE_ACTIVE |
| `settle` / `settle_with_receipt` | Anyone | CONDITIONS_MET, STATE_ACTIVE |
| `arbiter_settle` | arbiter | STATE_ACTIVE |
| `cancel` | creator (CREATED) or party (ACTIVE) | Only one party deposited |
| `mutual_cancel` | party_a, party_b | STATE_ACTIVE, both consent |
| `arbiter_cancel` | arbiter | STATE_ACTIVE or STATE_DISPUTED |
| `cancel_expired` | Anyone | expiry_ms elapsed |
| `raise_dispute` | party_a, party_b | STATE_ACTIVE, arbiter set |
| `resolve_dispute` | arbiter | STATE_DISPUTED |
| `resolve_dispute_split_coin` | arbiter | STATE_DISPUTED |
| `resolve_dispute_assign_object` | arbiter | STATE_DISPUTED |
| `conclude_dispute` | arbiter | STATE_DISPUTED, active_slots == 0 |
| `claim_coin/object` | designated recipient only | STATE_SETTLED or CANCELLED, timelock |
| `extract_coin_balance/object` | designated recipient only | STATE_SETTLED or CANCELLED, timelock |
| `attach_hook` | party_a, party_b, creator | agreement not finalized |
| `extract_hook` | party_a, party_b, creator | agreement finalized |
| `extract_hook_with_receipt` | Anyone holding SettlementReceipt | agreement finalized, receipt matches |
| `record_outcome` | Anyone | agreement finalized, not yet recorded |
| `destroy` | Anyone with the Agreement | active_slots == 0, finalized, no hook |

### Key Security Properties

**1. No Unilateral Release Power**
Settlement is enforced by the condition bitmask. No single party, not even the creator or arbiter, can release funds unilaterally through the normal settlement path. `approve()` only sets a flag — it does not move assets.

**2. Recipient Verification on Every Claim**
`claim_coin`, `claim_object`, `extract_coin_balance`, `extract_object` all assert `ctx.sender() == recipient`. The routing (`a_recipient`, `b_recipient`) is set exactly once at finalization and cannot be changed. There is no function that allows post-finalization re-routing.

**3. Bait-and-Bail Attack Prevention**
`cancel()` aborts if `a_deposited && b_deposited`. A party cannot deposit to establish credibility and then cancel to strand the counterparty. Once both have deposited, only `mutual_cancel()` (both consent) or arbiter intervention can cancel.

**4. Safe Destruction — active_slots Guard**
`destroy()` aborts unless `active_slots == 0`. This counter is incremented on every deposit (first coin deposit per type, every object deposit) and decremented on every claim, extract, split, or assign. Any remaining asset makes `active_slots > 0`, making it impossible to destroy an agreement with locked funds.

**5. Cross-Delivery Atomicity**
Routing is set in `finalize_settle()` as a single atomic operation. `a_recipient = party_b` and `b_recipient = party_a` are set together. There is no intermediate state where only one side is set.

**6. Hook Extraction — Receipt-Gated Authorization**
`extract_hook_with_receipt` allows executor/bot hook extraction without party authorization, but requires a `SettlementReceipt` as proof. The receipt is produced only by `settle_with_receipt()` in the same PTB, so the caller is always the address that triggered settlement. No address can extract a hook without either being a party (`extract_hook`) or holding the receipt. The receipt also binds to a specific `agreement_id`, preventing receipt reuse across agreements.

**7. Expiry Safety Net**
`cancel_expired()` is permissionless. If both parties go inactive, any address (bot, other party, random user) can cancel after `expiry_ms`, preventing permanent fund lock.

**8. Registry Double-Count Prevention**
`record_outcome()` is permissionless but each agreement can only be recorded once. The `registry_recorded` flag on the Agreement itself tracks this — the record operation uses the Agreement as cryptographic proof of its own outcome.

---

## Function Reference

### Creation

**`create_agreement(...) → Agreement`**
Returns the agreement object. Caller chooses to `transfer::share_object()`, wrap inside their own struct, or transfer to an address.

**`create_and_share(...)`** — Entry: creates and immediately shares.

### Deposits

**`deposit_coin<T>(agreement, coin, clock, ctx)`**
Deposits fungible token. First deposit of a type opens a new slot (`active_slots + 1`). Same-party same-type top-ups merge into the existing balance without opening new slots. Triggers auto-settle check.

**`deposit_object<V: key + store>(agreement, object, clock, ctx)`**
Deposits any Sui object. Each object gets its own indexed slot (`active_slots + 1`). Triggers auto-settle check.

### Settlement

**`settle(agreement, clock, ctx)`** — Entry, permissionless. Triggers settlement when all conditions met.

**`settle_with_receipt(agreement, clock, ctx) → SettlementReceipt`** — Returns hot potato. External protocols MUST consume in same PTB.

**`consume_settlement_receipt(receipt) → (ID, address, address, u64)`** — Destroys receipt, returns inner fields.

**`arbiter_settle(agreement, clock, ctx)`** — Arbiter forces settlement with cross-delivery routing. For `release_conditions = 0` agreements or off-chain agreements needing on-chain execution.

### Cancellation

**`cancel(agreement, ctx)`** — Creator/party. Blocked if both deposited.

**`mutual_cancel(agreement, ctx)`** — Cooperative unwind. Fires when both parties have called.

**`cancel_expired(agreement, clock, ctx)`** — Permissionless after `expiry_ms`.

**`arbiter_cancel(agreement, ctx)`** — Arbiter cancels active or disputed agreement.

### Disputes

**`raise_dispute(agreement, reason, ctx)`** — Either party, requires arbiter.

**`resolve_dispute(agreement, resolution, ctx)`** — Arbiter awards all to A (0) or B (1). State → SETTLED.

**`resolve_dispute_split_coin<T>(agreement, a_bps, ctx)`** — Splits a coin type proportionally. Immediate transfer. State stays DISPUTED (multiple types can each be split).

**`resolve_dispute_assign_object<V>(agreement, source_party, index, recipient, ctx)`** — Assigns object to a party. Immediate transfer. State stays DISPUTED.

**`conclude_dispute(agreement, clock, ctx)`** — Finalizes dispute. Requires `active_slots == 0`. State → DISPUTE_RESOLVED.

### Claims

**`claim_coin<T>(agreement, source_party, clock, ctx) → Coin<T>`** — Enforces recipient check + timelock.

**`claim_object<V>(agreement, source_party, index, clock, ctx) → V`** — Same for objects.

**`claim_coin_to_sender<T>(...)`** / **`claim_object_to_sender<V>(...)`** — Entry wrappers with auto-transfer.

### Composability Extraction

**`extract_coin_balance<T>(agreement, source_party, clock, ctx) → Balance<T>`** — Raw balance for protocol-level routing (pools, vaults). Enforces recipient check.

**`extract_object<V>(agreement, source_party, index, clock, ctx) → V`** — Raw object for programmatic routing.

### Hooks

**`attach_hook<H: key + store>(agreement, hook, ctx)`** — Store execution context on agreement. Parties/creator only.

**`extract_hook<H: key + store>(agreement, ctx) → H`** — Retrieve post-finalization. Parties/creator only.

**`extract_hook_with_receipt<H>(agreement, &receipt) → H`** — Receipt-authorized extraction. Executor holds the SettlementReceipt as proof. Call before `consume_settlement_receipt()`.

### Registry

**`record_outcome(agreement, registry)`** — Permissionless. Updates `total_settled` or `total_cancelled`. Each agreement records once.

**`record_settled/cancelled/disputed(_cap, registry)`** — Admin-gated manual stat update (legacy; prefer `record_outcome`).

### View Functions

```move
// State predicates
is_created(a)  is_active(a)  is_settled(a)  is_cancelled(a)
is_disputed(a) is_dispute_resolved(a) is_finalized(a)
is_ready_to_settle(a, clock)
both_deposited(a)  both_approved(a)

// Party data
get_party_a(a)  get_party_b(a)  get_arbiter(a)  get_creator(a)
get_state(a)    get_release_conditions(a)
get_a_deposited(a)  get_b_deposited(a)
get_a_approved(a)   get_b_approved(a)
get_a_recipient(a)  get_b_recipient(a)
get_a_obj_count(a)  get_b_obj_count(a)
get_active_slots(a) get_hook_attached(a)  get_registry_recorded(a)
get_expiry_ms(a)    get_unlock_time_ms(a)
get_created_at_ms(a) get_settled_at_ms(a)
get_terms_hash(a)   get_metadata(a)       get_version(a)

// Deposit existence
has_coin_deposit<T>(a, party)
has_object_deposit(a, party, index)

// Condition constants (for integrators)
cond_a_deposited()  cond_b_deposited()
cond_a_approved()   cond_b_approved()
cond_timelock()
party_a_id()  party_b_id()
protocol_version()

// Receipt (non-consuming)
receipt_agreement_id(r)   receipt_a_recipient(r)
receipt_b_recipient(r)    receipt_settled_at_ms(r)
```

---

## Integration Guide

### 1. Minimal Integration — Atomic Coin Swap

```move
module my_protocol::swap {
    use pacta::pacta;
    use sui::coin::Coin;
    use sui::clock::Clock;

    /// Create a coin-for-coin atomic swap using Pacta.
    public fun create_swap<A>(
        offer: Coin<A>,
        counterparty: address,
        expiry_ms: u64,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        // COND_A_DEPOSITED | COND_B_DEPOSITED = 3
        let conditions = pacta::cond_a_deposited() | pacta::cond_b_deposited();

        let mut agreement = pacta::create_agreement(
            ctx.sender(), counterparty, @0x0,
            conditions, b"swap", expiry_ms, 0, b"", clock, ctx,
        );

        // Deposit maker's offer. Counterparty will deposit via their own tx.
        pacta::deposit_coin<A>(&mut agreement, offer, clock, ctx);
        transfer::share_object(agreement);
    }
}
```

### 2. Receipt Composability — DEX Integration

```move
module my_dex::routing {
    use pacta::pacta::{Self, SettlementReceipt};

    /// Called in same PTB as settle_with_receipt().
    /// The receipt proves settlement happened — route fee accordingly.
    public fun on_pacta_settle(
        receipt: SettlementReceipt,
        pool: &mut Pool,
    ) {
        let (agreement_id, a_recipient, b_recipient, _) =
            pacta::consume_settlement_receipt(receipt);

        // Route fee, update order book, emit DEX event — all atomic.
        route_protocol_fee(pool, a_recipient, b_recipient, agreement_id);
    }
}
```

### 3. Wrapping — Lending Protocol

```move
module lending::collateral {
    use pacta::pacta::Agreement;

    /// Wrap a Pacta agreement inside the lending protocol's collateral struct.
    /// The agreement holds the borrower's collateral assets in Pacta escrow.
    public struct CollateralVault has key {
        id: UID,
        agreement: Agreement,   // Agreement has 'store' — can be wrapped
        loan_amount: u64,
        borrower: address,
    }
}
```

### 4. Freelance Escrow — Condition-Based Release

```move
module freelance::milestone {
    use pacta::pacta;

    // Client (A) deposits. Releases when client approves (COND_A_APR).
    // release_conditions = COND_A_DEPOSITED | COND_A_APPROVED = 5
    public fun create_milestone(freelancer: address, clock: &Clock, ctx: &mut TxContext) {
        let conditions = pacta::cond_a_deposited() | pacta::cond_a_approved();
        let ag = pacta::create_agreement(
            ctx.sender(), freelancer, @0x0, conditions,
            b"milestone", 0, 0, b"", clock, ctx,
        );
        transfer::share_object(ag);
    }
}
```

### 5. Vesting — Timelock Pattern

```move
module dao::vesting {
    use pacta::pacta;

    // DAO deposits tokens. Releases after unlock_time_ms.
    // release_conditions = COND_A_DEPOSITED | COND_TIMELOCK = 17
    public fun create_vest(
        contributor: address,
        unlock_time_ms: u64,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        let conditions = pacta::cond_a_deposited() | pacta::cond_timelock();
        let ag = pacta::create_agreement(
            ctx.sender(), contributor, @0x0, conditions,
            b"vest", 0, unlock_time_ms, b"", clock, ctx,
        );
        transfer::share_object(ag);
        // After unlock_time_ms: any bot calls settle(), contributor claims.
    }
}
```

---

## AI Agent & Automation Support

Pacta has no human-only restrictions. Every function is callable by:
- Human wallets
- Smart contract modules
- Bot accounts
- AI agent wallets

Design properties that enable agent economy:
- **Permissionless creation**: agents can create agreements on behalf of users or autonomously
- **Permissionless settlement**: bots trigger settlement when conditions met (keeper network compatible)
- **Permissionless expiry**: bots can cancel expired agreements, earning gas refunds off-protocol
- **Permissionless stat recording**: indexer agents call `record_outcome()` to maintain on-chain stats
- **Receipt pattern**: agents in PTBs can consume receipts and execute follow-up logic atomically

Agents should:
1. Monitor `AgreementCreated` events for new agreements
2. Track condition status via `get_a_deposited()`, `get_b_deposited()`, etc.
3. Call `is_ready_to_settle()` before attempting `settle()`
4. Build PTBs with `settle_with_receipt()` + their callback for atomic settlement

---

## Gas & Performance Design

- **Parallel execution**: Agreements are shared objects but use fine-grained locking per-agreement. Unrelated agreements are fully parallel.
- **Cheap top-ups**: Same-party same-type coin deposits merge without opening new slots (`active_slots` unchanged, no new dynamic field allocation).
- **No cross-agreement state**: No global lock except the optional `PactaRegistry` (only updated by `record_outcome()`, which is a post-settlement convenience).
- **Minimal storage**: Dynamic fields only exist while assets are escrowed. After claiming, fields are deleted and storage freed.

---

## Invariants

These must always hold. Violation indicates a protocol bug.

1. `active_slots == (number of live CoinEscrow<T> fields) + (number of live ObjectEscrow fields)`
2. If `state ∈ {SETTLED, CANCELLED, DISPUTE_RESOLVED}` then `a_recipient != @0x0` (unless no assets were deposited)
3. `destroy()` can only succeed if `active_slots == 0 && !hook_attached && is_finalized()`
4. `a_deposited == true` iff at least one CoinEscrow or ObjectEscrow field for PARTY_A exists or was claimed
5. `registry_recorded` is monotonically false→true; never resets to false
