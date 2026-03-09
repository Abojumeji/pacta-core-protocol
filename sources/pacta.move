/// Pacta Core Protocol v4 — Institutional-Grade Settlement Infrastructure on Sui
///
/// Pacta is the settlement primitive of Sui. Infrastructure, not an application.
/// Other protocols (DEXes, NFT marketplaces, lending, OTC, AI agents) build on
/// Pacta the same way DeFi protocols build on DeepBook.
///
/// ─── Core Design Principles ──────────────────────────────────────────────────
///
///  1. TRUSTLESS CONDITION-BASED SETTLEMENT
///     Release is never gated by a single party. A bitmask of conditions
///     (deposited, approved, timelock) must ALL be satisfied. Any address —
///     including bots and AI agents — can trigger settlement permissionlessly.
///
///  2. ASSET-AGNOSTIC ESCROW
///     Agreement is NOT generic. Coins and objects are stored as dynamic fields
///     keyed by (party, type/index). One Agreement can hold SUI + USDC + an NFT
///     simultaneously. Zero generics on the core struct.
///
///  3. COMPOSABLE HOT-POTATO RECEIPTS
///     settle_with_receipt() returns a SettlementReceipt (no abilities — hot potato).
///     External modules MUST consume it in the same PTB, enabling atomic
///     settlement + callback patterns without trusted intermediaries.
///
///  4. PERMISSIONLESS EXECUTOR SYSTEM
///     Any address can trigger settlement once conditions are met. Executors
///     cannot steal funds — they only advance the state machine. The executor
///     address is recorded in the settlement event for attribution.
///
///  5. CAPABILITY-BASED SECURITY
///     AdminCap governs protocol parameters. Extract functions enforce strict
///     recipient verification. No function grants unilateral asset access.
///
///  6. SAFE DESTRUCTION
///     destroy() safely deletes fully-drained, finalized Agreements taken
///     by value. This is only reachable for owned or wrapped Agreements
///     (created via create_agreement() and held or wrapped by the caller).
///     Shared Agreements (via create_and_share / create_share_and_record)
///     are permanent on-chain objects — the Sui runtime never allows shared
///     objects to be passed by value. active_slots guards against fund loss.
///
/// ─── Lifecycle ───────────────────────────────────────────────────────────────
///
///  Created ──deposit()──► Active ──conditions met──► Settled ──claim()──► Done
///                             │
///                             ├──raise_dispute()──► Disputed
///                             │      ├──resolve_dispute()──► Settled (winner claims)
///                             │      └──split/assign + conclude()──► DisputeResolved
///                             └──cancel()/expire()──► Cancelled ──reclaim()──► Done
///
module pacta::pacta {
    use sui::dynamic_field as df;
    use sui::dynamic_object_field as dof;
    use sui::coin::{Self, Coin};
    use sui::balance::{Self, Balance};
    use sui::clock::Clock;
    use sui::event;

    // ═══════════════════════════════════════════════════════════════════
    // Protocol Version
    // ═══════════════════════════════════════════════════════════════════

    const VERSION: u64 = 4;

    // ═══════════════════════════════════════════════════════════════════
    // Error Codes
    // ═══════════════════════════════════════════════════════════════════

    const ENotParty: u64               = 0;
    const EInvalidState: u64           = 1;
    const ENotArbiter: u64             = 2;
    const EExpired: u64                = 3;
    const ENotExpired: u64             = 4;
    const EUnlockTimeNotReached: u64   = 5;
    const EZeroDeposit: u64            = 6;
    const EConditionsNotMet: u64       = 7;
    const ENotRecipient: u64           = 8;
    const EDepositNotFound: u64        = 9;
    const EInvalidResolution: u64      = 10;
    const ENotCreator: u64             = 11;
    const ENoArbiter: u64              = 12;
    const ECannotCancelBothDeposited: u64 = 13;
    const EHasUnclaimedAssets: u64     = 14;
    const EInvalidBps: u64             = 15;
    const ENotAuthorized: u64          = 16;
    const EAlreadyHookAttached: u64    = 17;
    const ENoHookAttached: u64         = 18;
    const EPartyBAlreadyDeposited: u64 = 19;
    const EAlreadyRecorded: u64        = 20;
    const EInvalidAgreement: u64       = 21;

    // ═══════════════════════════════════════════════════════════════════
    // Agreement States
    // ═══════════════════════════════════════════════════════════════════

    const STATE_CREATED: u8          = 0;
    const STATE_ACTIVE: u8           = 1;
    const STATE_SETTLED: u8          = 2;
    const STATE_CANCELLED: u8        = 3;
    const STATE_DISPUTED: u8         = 4;
    // Assets directly distributed by arbiter (split/assign path).
    // Terminal state — no further claims via claim_coin/claim_object.
    const STATE_DISPUTE_RESOLVED: u8 = 5;

    // ═══════════════════════════════════════════════════════════════════
    // Party Identifiers
    // ═══════════════════════════════════════════════════════════════════

    const PARTY_A: u8 = 0;
    const PARTY_B: u8 = 1;

    // ═══════════════════════════════════════════════════════════════════
    // Release Condition Flags (bitmask)
    //
    // release_conditions is stored on the Agreement. Auto-settlement fires
    // when ALL flagged bits are simultaneously satisfied.
    //
    // Presets:
    //   Atomic swap:     COND_A_DEPOSITED | COND_B_DEPOSITED  = 0x03
    //   Service escrow:  COND_A_DEPOSITED | COND_A_APPROVED   = 0x05
    //   Mutual sign-off: COND_A_APPROVED  | COND_B_APPROVED   = 0x0C
    //   Vesting:         COND_A_DEPOSITED | COND_TIMELOCK      = 0x11
    //   Arbiter-only:    0x00 (no auto-settle)
    // ═══════════════════════════════════════════════════════════════════

    const COND_A_DEPOSITED: u8 = 1;
    const COND_B_DEPOSITED: u8 = 2;
    const COND_A_APPROVED: u8  = 4;
    const COND_B_APPROVED: u8  = 8;
    const COND_TIMELOCK: u8    = 16;

    // ═══════════════════════════════════════════════════════════════════
    // Dynamic Field Keys
    // ═══════════════════════════════════════════════════════════════════

    /// Key for fungible token escrow. Unique per (party, coin type T).
    public struct CoinEscrow<phantom T> has copy, drop, store { party: u8 }

    /// Key for object/NFT escrow. Unique per (party, deposit index).
    public struct ObjectEscrow has copy, drop, store { party: u8, index: u64 }

    /// Key for the optional settlement hook. One slot per agreement.
    public struct HookKey has copy, drop, store {}

    // ═══════════════════════════════════════════════════════════════════
    // Core Struct
    // ═══════════════════════════════════════════════════════════════════

    /// The settlement primitive. Non-generic. Asset-agnostic.
    /// Can be shared (permissionless) or wrapped (owned by another protocol).
    ///
    /// All escrowed assets live as dynamic fields on this object.
    /// active_slots is the authoritative count of live escrow entries.
    public struct Agreement has key, store {
        id: UID,
        version: u64,
        creator: address,
        party_a: address,
        party_b: address,          // @0x0 = open; set via set_party_b()
        arbiter: address,          // @0x0 = none
        state: u8,
        release_conditions: u8,
        a_deposited: bool,
        b_deposited: bool,
        a_approved: bool,
        b_approved: bool,
        a_cancel_consent: bool,
        b_cancel_consent: bool,
        a_obj_count: u64,          // Monotonic object counter for party A
        b_obj_count: u64,          // Monotonic object counter for party B
        active_slots: u64,         // Live escrow entries. Must reach 0 before destroy.
        hook_attached: bool,
        a_recipient: address,      // Set on finalization: who gets party A's assets
        b_recipient: address,      // Set on finalization: who gets party B's assets
        registry_recorded: bool,   // True after record_outcome() called — prevents double-count
        terms_hash: vector<u8>,
        expiry_ms: u64,            // 0 = no expiry
        unlock_time_ms: u64,       // 0 = immediate claims allowed
        created_at_ms: u64,
        settled_at_ms: u64,        // 0 = not yet finalized
        metadata: vector<u8>,
    }

    // ═══════════════════════════════════════════════════════════════════
    // Protocol Registry
    // ═══════════════════════════════════════════════════════════════════

    public struct PactaRegistry has key {
        id: UID,
        version: u64,
        total_agreements: u64,
        total_settled: u64,
        total_cancelled: u64,
        total_disputed: u64,
    }

    public struct AdminCap has key, store { id: UID }

    // ═══════════════════════════════════════════════════════════════════
    // Settlement Receipt — Hot Potato
    // ═══════════════════════════════════════════════════════════════════

    /// Zero abilities — true hot potato. Cannot be stored, copied, or dropped.
    /// Returned by settle_with_receipt(). MUST be consumed in the same PTB.
    ///
    /// This is the core composability primitive. External protocols use this to
    /// react atomically to settlement (update order books, route fees, etc.).
    public struct SettlementReceipt {
        agreement_id: ID,
        a_recipient: address,
        b_recipient: address,
        settled_at_ms: u64,
    }

    // ═══════════════════════════════════════════════════════════════════
    // Events
    // ═══════════════════════════════════════════════════════════════════

    public struct AgreementCreated has copy, drop {
        agreement_id: ID,
        version: u64,
        creator: address,
        party_a: address,
        party_b: address,
        arbiter: address,
        release_conditions: u8,
        expiry_ms: u64,
        unlock_time_ms: u64,
    }

    public struct PartyBSet has copy, drop {
        agreement_id: ID,
        new_party_b: address,
        set_by: address,
    }

    public struct CoinDeposited has copy, drop {
        agreement_id: ID,
        depositor: address,
        party: u8,
        amount: u64,
    }

    public struct ObjectDeposited has copy, drop {
        agreement_id: ID,
        depositor: address,
        party: u8,
        object_id: ID,
        index: u64,
    }

    public struct PartyApproved has copy, drop {
        agreement_id: ID,
        party: u8,
        approved_by: address,
    }

    // executor: who triggered settlement (@0x0 = auto-triggered during deposit/approve)
    public struct AgreementSettled has copy, drop {
        agreement_id: ID,
        executor: address,
        a_recipient: address,
        b_recipient: address,
        settled_at_ms: u64,
    }

    public struct AgreementCancelled has copy, drop {
        agreement_id: ID,
        cancelled_by: address,
    }

    public struct MutualCancelConsent has copy, drop {
        agreement_id: ID,
        party: u8,
        by: address,
    }

    public struct CoinClaimed has copy, drop {
        agreement_id: ID,
        claimed_by: address,
        source_party: u8,
        amount: u64,
    }

    public struct ObjectClaimed has copy, drop {
        agreement_id: ID,
        claimed_by: address,
        source_party: u8,
        object_id: ID,
    }

    public struct DisputeRaised has copy, drop {
        agreement_id: ID,
        raised_by: address,
        reason: vector<u8>,
    }

    // resolution: 0=favor A | 1=favor B | 2=coin split | 3=obj assigned | 4=concluded
    public struct DisputeResolved has copy, drop {
        agreement_id: ID,
        arbiter: address,
        resolution: u8,
    }

    public struct HookAttached has copy, drop {
        agreement_id: ID,
        attached_by: address,
    }

    // ═══════════════════════════════════════════════════════════════════
    // Initialization
    // ═══════════════════════════════════════════════════════════════════

    fun init(ctx: &mut TxContext) {
        transfer::share_object(PactaRegistry {
            id: object::new(ctx),
            version: VERSION,
            total_agreements: 0,
            total_settled: 0,
            total_cancelled: 0,
            total_disputed: 0,
        });
        transfer::transfer(AdminCap { id: object::new(ctx) }, ctx.sender());
    }

    // ═══════════════════════════════════════════════════════════════════
    // Creation
    // ═══════════════════════════════════════════════════════════════════

    /// Create a new agreement. Returns it for the caller to share or wrap.
    ///
    /// release_conditions: bitmask of COND_* flags (0 = arbiter-only, no auto-settle).
    /// party_b: pass @0x0 for open agreements; set counterparty via set_party_b().
    /// Creator may be any address including a contract — no human-only restrictions.
    public fun create_agreement(
        party_a: address,
        party_b: address,
        arbiter: address,
        release_conditions: u8,
        terms_hash: vector<u8>,
        expiry_ms: u64,
        unlock_time_ms: u64,
        metadata: vector<u8>,
        clock: &Clock,
        ctx: &mut TxContext,
    ): Agreement {
        let creator = ctx.sender();
        let id = object::new(ctx);
        let agreement_id = id.to_inner();

        let agreement = Agreement {
            id,
            version: VERSION,
            creator,
            party_a,
            party_b,
            arbiter,
            state: STATE_CREATED,
            release_conditions,
            a_deposited: false,
            b_deposited: false,
            a_approved: false,
            b_approved: false,
            a_cancel_consent: false,
            b_cancel_consent: false,
            a_obj_count: 0,
            b_obj_count: 0,
            active_slots: 0,
            hook_attached: false,
            a_recipient: @0x0,
            b_recipient: @0x0,
            registry_recorded: false,
            terms_hash,
            expiry_ms,
            unlock_time_ms,
            created_at_ms: clock.timestamp_ms(),
            settled_at_ms: 0,
            metadata,
        };

        event::emit(AgreementCreated {
            agreement_id,
            version: VERSION,
            creator,
            party_a,
            party_b,
            arbiter,
            release_conditions,
            expiry_ms,
            unlock_time_ms,
        });

        agreement
    }

    /// Convenience entry: creates and shares the agreement.
    ///
    /// IMPORTANT — Shared Agreements are permanent on-chain objects.
    /// Once shared, the Sui runtime never allows the object to be taken
    /// by value, so destroy() is unreachable for Agreements created here.
    /// Use create_agreement() directly if you need a destroyable, owned
    /// or wrapped Agreement (e.g. a protocol that wraps it in its own struct).
    entry fun create_and_share(
        party_a: address,
        party_b: address,
        arbiter: address,
        release_conditions: u8,
        terms_hash: vector<u8>,
        expiry_ms: u64,
        unlock_time_ms: u64,
        metadata: vector<u8>,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        let ag = create_agreement(
            party_a, party_b, arbiter, release_conditions,
            terms_hash, expiry_ms, unlock_time_ms, metadata, clock, ctx,
        );
        transfer::share_object(ag);
    }

    /// Creates, records in global registry, and shares the agreement.
    entry fun create_share_and_record(
        registry: &mut PactaRegistry,
        party_a: address,
        party_b: address,
        arbiter: address,
        release_conditions: u8,
        terms_hash: vector<u8>,
        expiry_ms: u64,
        unlock_time_ms: u64,
        metadata: vector<u8>,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        let ag = create_agreement(
            party_a, party_b, arbiter, release_conditions,
            terms_hash, expiry_ms, unlock_time_ms, metadata, clock, ctx,
        );
        registry.total_agreements = registry.total_agreements + 1;
        transfer::share_object(ag);
    }

    // ═══════════════════════════════════════════════════════════════════
    // Party Management
    // ═══════════════════════════════════════════════════════════════════

    /// Set or update party_b before party B makes any deposit.
    /// Enables open-listing patterns. Only the creator can call.
    public fun set_party_b(
        agreement: &mut Agreement,
        new_party_b: address,
        ctx: &mut TxContext,
    ) {
        let sender = ctx.sender();
        assert!(sender == agreement.creator, ENotCreator);
        assert!(!agreement.b_deposited, EPartyBAlreadyDeposited);
        assert!(
            agreement.state == STATE_CREATED || agreement.state == STATE_ACTIVE,
            EInvalidState,
        );
        agreement.party_b = new_party_b;
        event::emit(PartyBSet {
            agreement_id: object::id(agreement),
            new_party_b,
            set_by: sender,
        });
    }

    // ═══════════════════════════════════════════════════════════════════
    // Deposits — Coins
    // ═══════════════════════════════════════════════════════════════════

    /// Deposit a fungible token into escrow.
    /// Same-party same-type top-ups merge (no new slot). Only the first deposit
    /// of a given coin type by a party opens a new slot (active_slots + 1).
    /// Triggers auto-settle check after deposit.
    public fun deposit_coin<T>(
        agreement: &mut Agreement,
        payment: Coin<T>,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        let sender = ctx.sender();
        let amount = payment.value();
        assert!(amount > 0, EZeroDeposit);

        let party = resolve_party(agreement, sender);
        assert!(
            agreement.state == STATE_CREATED || agreement.state == STATE_ACTIVE,
            EInvalidState,
        );
        if (agreement.expiry_ms > 0) {
            assert!(clock.timestamp_ms() < agreement.expiry_ms, EExpired);
        };

        let key = CoinEscrow<T> { party };
        if (df::exists_(&agreement.id, key)) {
            let existing: &mut Balance<T> = df::borrow_mut(&mut agreement.id, key);
            existing.join(payment.into_balance());
        } else {
            df::add(&mut agreement.id, key, payment.into_balance());
            agreement.active_slots = agreement.active_slots + 1;
        };

        if (party == PARTY_A) { agreement.a_deposited = true; }
        else { agreement.b_deposited = true; };

        if (agreement.state == STATE_CREATED) { agreement.state = STATE_ACTIVE; };

        event::emit(CoinDeposited {
            agreement_id: object::id(agreement),
            depositor: sender,
            party,
            amount,
        });

        try_auto_settle(agreement, clock, sender);
    }

    // ═══════════════════════════════════════════════════════════════════
    // Deposits — Objects
    // ═══════════════════════════════════════════════════════════════════

    /// Deposit any Sui object (NFT, receipt, proof) into escrow.
    /// Each object gets its own indexed slot. Triggers auto-settle check.
    public fun deposit_object<V: key + store>(
        agreement: &mut Agreement,
        object: V,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        let sender = ctx.sender();
        let party = resolve_party(agreement, sender);
        let obj_id = object::id(&object);

        assert!(
            agreement.state == STATE_CREATED || agreement.state == STATE_ACTIVE,
            EInvalidState,
        );
        if (agreement.expiry_ms > 0) {
            assert!(clock.timestamp_ms() < agreement.expiry_ms, EExpired);
        };

        let index = if (party == PARTY_A) {
            let idx = agreement.a_obj_count;
            agreement.a_obj_count = idx + 1;
            idx
        } else {
            let idx = agreement.b_obj_count;
            agreement.b_obj_count = idx + 1;
            idx
        };

        dof::add(&mut agreement.id, ObjectEscrow { party, index }, object);
        agreement.active_slots = agreement.active_slots + 1;

        if (party == PARTY_A) { agreement.a_deposited = true; }
        else { agreement.b_deposited = true; };

        if (agreement.state == STATE_CREATED) { agreement.state = STATE_ACTIVE; };

        event::emit(ObjectDeposited {
            agreement_id: object::id(agreement),
            depositor: sender,
            party,
            object_id: obj_id,
            index,
        });

        try_auto_settle(agreement, clock, sender);
    }

    // ═══════════════════════════════════════════════════════════════════
    // Approval
    // ═══════════════════════════════════════════════════════════════════

    /// Signal explicit approval from a party.
    /// Required for COND_A_APPROVED / COND_B_APPROVED release modes.
    /// Idempotent — calling twice is safe. Triggers auto-settle check.
    public fun approve(
        agreement: &mut Agreement,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        let sender = ctx.sender();
        let party = resolve_party(agreement, sender);
        assert!(agreement.state == STATE_ACTIVE, EInvalidState);

        if (party == PARTY_A) { agreement.a_approved = true; }
        else { agreement.b_approved = true; };

        event::emit(PartyApproved {
            agreement_id: object::id(agreement),
            party,
            approved_by: sender,
        });

        try_auto_settle(agreement, clock, sender);
    }

    // ═══════════════════════════════════════════════════════════════════
    // Settlement
    // ═══════════════════════════════════════════════════════════════════

    /// Permissionless settlement trigger.
    /// Any address (bot, AI agent, user) can call once all conditions are met.
    /// Executor cannot redirect funds — only advances the state machine.
    entry fun settle(
        agreement: &mut Agreement,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        assert!(agreement.state == STATE_ACTIVE, EInvalidState);
        assert!(agreement.release_conditions > 0, EConditionsNotMet);
        assert!(check_conditions(agreement, clock), EConditionsNotMet);
        finalize_settle(agreement, clock, ctx.sender());
    }

    /// Non-entry settlement returning a SettlementReceipt hot potato.
    /// External protocols MUST consume the receipt in the same PTB.
    /// This is the primary composability primitive — enables atomic
    /// settlement + callback patterns (DEX, NFT marketplace, lending).
    public fun settle_with_receipt(
        agreement: &mut Agreement,
        clock: &Clock,
        ctx: &mut TxContext,
    ): SettlementReceipt {
        assert!(agreement.state == STATE_ACTIVE, EInvalidState);
        assert!(agreement.release_conditions > 0, EConditionsNotMet);
        assert!(check_conditions(agreement, clock), EConditionsNotMet);
        finalize_settle(agreement, clock, ctx.sender());

        SettlementReceipt {
            agreement_id: object::id(agreement),
            a_recipient: agreement.a_recipient,
            b_recipient: agreement.b_recipient,
            settled_at_ms: agreement.settled_at_ms,
        }
    }

    /// Consume a SettlementReceipt hot potato. Returns the inner fields.
    /// The receipt is destroyed here — callers must handle the returned values.
    public fun consume_settlement_receipt(
        receipt: SettlementReceipt,
    ): (ID, address, address, u64) {
        let SettlementReceipt { agreement_id, a_recipient, b_recipient, settled_at_ms } = receipt;
        (agreement_id, a_recipient, b_recipient, settled_at_ms)
    }

    /// View: true if all conditions are satisfied and settle() would succeed right now.
    public fun is_ready_to_settle(agreement: &Agreement, clock: &Clock): bool {
        agreement.state == STATE_ACTIVE
            && agreement.release_conditions > 0
            && check_conditions(agreement, clock)
    }

    fun check_conditions(agreement: &Agreement, clock: &Clock): bool {
        let required = agreement.release_conditions;
        if (required == 0) return false;

        let mut met: u8 = 0;
        if (agreement.a_deposited) { met = met | COND_A_DEPOSITED; };
        if (agreement.b_deposited) { met = met | COND_B_DEPOSITED; };
        if (agreement.a_approved)  { met = met | COND_A_APPROVED; };
        if (agreement.b_approved)  { met = met | COND_B_APPROVED; };
        if (agreement.unlock_time_ms == 0 ||
            clock.timestamp_ms() >= agreement.unlock_time_ms) {
            met = met | COND_TIMELOCK;
        };
        (met & required) == required
    }

    fun finalize_settle(agreement: &mut Agreement, clock: &Clock, executor: address) {
        agreement.state = STATE_SETTLED;
        agreement.a_recipient = agreement.party_b; // cross-delivery
        agreement.b_recipient = agreement.party_a;
        agreement.settled_at_ms = clock.timestamp_ms();

        event::emit(AgreementSettled {
            agreement_id: object::id(agreement),
            executor,
            a_recipient: agreement.a_recipient,
            b_recipient: agreement.b_recipient,
            settled_at_ms: agreement.settled_at_ms,
        });
    }

    fun try_auto_settle(agreement: &mut Agreement, clock: &Clock, executor: address) {
        if (agreement.state != STATE_ACTIVE) return;
        if (agreement.release_conditions == 0) return;
        if (!check_conditions(agreement, clock)) return;
        finalize_settle(agreement, clock, executor);
    }

    // ═══════════════════════════════════════════════════════════════════
    // Cancellation
    // ═══════════════════════════════════════════════════════════════════

    /// Cancel with self-refund routing (each party gets own deposits back).
    ///
    /// CREATED state: only creator can cancel.
    /// ACTIVE + one party deposited: either party can cancel.
    /// ACTIVE + both deposited: BLOCKED — prevents "bait-and-bail" attacks.
    ///   Use mutual_cancel() for cooperative exit or raise_dispute() for conflict.
    public fun cancel(
        agreement: &mut Agreement,
        ctx: &mut TxContext,
    ) {
        let sender = ctx.sender();
        if (agreement.state == STATE_CREATED) {
            assert!(sender == agreement.creator, ENotCreator);
        } else if (agreement.state == STATE_ACTIVE) {
            assert!(
                sender == agreement.party_a || sender == agreement.party_b,
                ENotParty,
            );
            assert!(
                !(agreement.a_deposited && agreement.b_deposited),
                ECannotCancelBothDeposited,
            );
        } else {
            abort EInvalidState
        };
        finalize_cancel(agreement, sender);
    }

    /// Mutual cancellation — cooperative unwind when both parties have deposited.
    /// First caller signals consent. Cancellation fires only when BOTH have called.
    public fun mutual_cancel(
        agreement: &mut Agreement,
        ctx: &mut TxContext,
    ) {
        let sender = ctx.sender();
        let party = resolve_party(agreement, sender);
        assert!(agreement.state == STATE_ACTIVE, EInvalidState);

        if (party == PARTY_A) { agreement.a_cancel_consent = true; }
        else { agreement.b_cancel_consent = true; };

        event::emit(MutualCancelConsent {
            agreement_id: object::id(agreement),
            party,
            by: sender,
        });

        if (agreement.a_cancel_consent && agreement.b_cancel_consent) {
            finalize_cancel(agreement, sender);
        };
    }

    /// Cancel an expired agreement. Permissionless — any address can call.
    /// Prevents permanent fund lock if both parties go inactive.
    public fun cancel_expired(
        agreement: &mut Agreement,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        assert!(
            agreement.state == STATE_CREATED || agreement.state == STATE_ACTIVE,
            EInvalidState,
        );
        assert!(agreement.expiry_ms > 0, ENotExpired);
        assert!(clock.timestamp_ms() >= agreement.expiry_ms, ENotExpired);
        finalize_cancel(agreement, ctx.sender());
    }

    fun finalize_cancel(agreement: &mut Agreement, cancelled_by: address) {
        agreement.state = STATE_CANCELLED;
        agreement.a_recipient = agreement.party_a; // self-refund
        agreement.b_recipient = agreement.party_b;
        event::emit(AgreementCancelled {
            agreement_id: object::id(agreement),
            cancelled_by,
        });
    }

    // ═══════════════════════════════════════════════════════════════════
    // Disputes
    // ═══════════════════════════════════════════════════════════════════

    /// Raise a dispute. Freezes the agreement. Requires an arbiter to be set.
    public fun raise_dispute(
        agreement: &mut Agreement,
        reason: vector<u8>,
        ctx: &mut TxContext,
    ) {
        let sender = ctx.sender();
        assert!(
            sender == agreement.party_a || sender == agreement.party_b,
            ENotParty,
        );
        assert!(agreement.state == STATE_ACTIVE, EInvalidState);
        assert!(agreement.arbiter != @0x0, ENoArbiter);

        agreement.state = STATE_DISPUTED;
        event::emit(DisputeRaised {
            agreement_id: object::id(agreement),
            raised_by: sender,
            reason,
        });
    }

    /// Winner-takes-all resolution: 0 = all → A | 1 = all → B.
    /// Assets stay in escrow; winner claims via claim_coin/claim_object.
    /// State becomes SETTLED so the normal claim path works.
    public fun resolve_dispute(
        agreement: &mut Agreement,
        resolution: u8,
        ctx: &mut TxContext,
    ) {
        assert!(ctx.sender() == agreement.arbiter, ENotArbiter);
        assert!(agreement.state == STATE_DISPUTED, EInvalidState);
        assert!(resolution <= 1, EInvalidResolution);

        if (resolution == 0) {
            agreement.a_recipient = agreement.party_a;
            agreement.b_recipient = agreement.party_a;
        } else {
            agreement.a_recipient = agreement.party_b;
            agreement.b_recipient = agreement.party_b;
        };
        agreement.state = STATE_SETTLED;

        event::emit(DisputeResolved {
            agreement_id: object::id(agreement),
            arbiter: ctx.sender(),
            resolution,
        });
    }

    /// Split a specific coin type proportionally. Immediate direct transfer.
    /// State stays DISPUTED so multiple coin types can each be split.
    ///
    /// SECURITY FIX vs v2: State is NOT changed to SETTLED here.
    /// The v2 bug: splitting one coin type locked out all other coin types.
    /// Fix: state remains DISPUTED; call conclude_dispute() when all done.
    ///
    /// a_bps: basis points 0-10000 of combined total going to party A.
    public fun resolve_dispute_split_coin<T>(
        agreement: &mut Agreement,
        a_bps: u64,
        ctx: &mut TxContext,
    ) {
        assert!(ctx.sender() == agreement.arbiter, ENotArbiter);
        assert!(agreement.state == STATE_DISPUTED, EInvalidState);
        assert!(a_bps <= 10000, EInvalidBps);

        let agreement_id = object::id(agreement);
        let mut combined = balance::zero<T>();

        let key_a = CoinEscrow<T> { party: PARTY_A };
        if (df::exists_(&agreement.id, key_a)) {
            combined.join(df::remove(&mut agreement.id, key_a));
            agreement.active_slots = agreement.active_slots - 1;
        };

        let key_b = CoinEscrow<T> { party: PARTY_B };
        if (df::exists_(&agreement.id, key_b)) {
            combined.join(df::remove(&mut agreement.id, key_b));
            agreement.active_slots = agreement.active_slots - 1;
        };

        let total = combined.value();
        let a_amount = (total * a_bps) / 10000;
        let b_amount = total - a_amount;

        if (a_amount > 0) {
            transfer::public_transfer(
                coin::from_balance(combined.split(a_amount), ctx),
                agreement.party_a,
            );
        };
        if (b_amount > 0) {
            transfer::public_transfer(
                coin::from_balance(combined.split(b_amount), ctx),
                agreement.party_b,
            );
        };
        combined.destroy_zero();

        // State intentionally left as STATE_DISPUTED.
        event::emit(DisputeResolved { agreement_id, arbiter: ctx.sender(), resolution: 2 });
    }

    /// Assign a specific escrowed object to a party. Immediate transfer.
    /// State stays DISPUTED. Call conclude_dispute() after all objects handled.
    public fun resolve_dispute_assign_object<V: key + store>(
        agreement: &mut Agreement,
        source_party: u8,
        index: u64,
        recipient: address,
        ctx: &mut TxContext,
    ) {
        assert!(ctx.sender() == agreement.arbiter, ENotArbiter);
        assert!(agreement.state == STATE_DISPUTED, EInvalidState);
        assert!(
            recipient == agreement.party_a || recipient == agreement.party_b,
            ENotParty,
        );

        let key = ObjectEscrow { party: source_party, index };
        let obj: V = dof::remove(&mut agreement.id, key);
        let obj_id = object::id(&obj);
        transfer::public_transfer(obj, recipient);
        agreement.active_slots = agreement.active_slots - 1;

        event::emit(ObjectClaimed {
            agreement_id: object::id(agreement),
            claimed_by: recipient,
            source_party,
            object_id: obj_id,
        });
        event::emit(DisputeResolved {
            agreement_id: object::id(agreement),
            arbiter: ctx.sender(),
            resolution: 3,
        });
    }

    /// Finalize a dispute after all assets have been directly distributed.
    ///
    /// Call this after all split/assign calls are complete.
    /// Requires active_slots == 0: arbiter must distribute ALL assets before concluding.
    /// This safety check prevents stranding any coin or object in the agreement.
    /// Transitions to STATE_DISPUTE_RESOLVED — no further claims possible.
    public fun conclude_dispute(
        agreement: &mut Agreement,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        assert!(ctx.sender() == agreement.arbiter, ENotArbiter);
        assert!(agreement.state == STATE_DISPUTED, EInvalidState);
        assert!(agreement.active_slots == 0, EHasUnclaimedAssets);

        agreement.state = STATE_DISPUTE_RESOLVED;
        agreement.settled_at_ms = clock.timestamp_ms();

        event::emit(DisputeResolved {
            agreement_id: object::id(agreement),
            arbiter: ctx.sender(),
            resolution: 4,
        });
    }

    // ═══════════════════════════════════════════════════════════════════
    // Arbiter Actions — Authority Settlement / Cancellation
    // ═══════════════════════════════════════════════════════════════════

    /// Arbiter forces settlement with standard cross-delivery routing.
    ///
    /// When to use:
    ///   - release_conditions = 0 (pure arbiter-mode, no auto-settle possible)
    ///   - Parties reached off-chain agreement; arbiter executes on-chain
    ///   - Arbiter wants to deliver assets without a dispute being raised
    ///
    /// Settlement routing: A's assets → party_b, B's assets → party_a.
    public fun arbiter_settle(
        agreement: &mut Agreement,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        let sender = ctx.sender();
        assert!(agreement.arbiter != @0x0, ENoArbiter);
        assert!(sender == agreement.arbiter, ENotArbiter);
        assert!(agreement.state == STATE_ACTIVE, EInvalidState);
        finalize_settle(agreement, clock, sender);
    }

    /// Arbiter forces cancellation with self-refund routing.
    ///
    /// Can be called on ACTIVE or DISPUTED agreements.
    /// When to use:
    ///   - Fraud or bad faith detected by arbiter
    ///   - Agreement conditions can never be met
    ///   - Arbiter determines unwind is correct outcome
    ///
    /// Cancellation routing: A's assets → party_a, B's assets → party_b.
    public fun arbiter_cancel(
        agreement: &mut Agreement,
        ctx: &mut TxContext,
    ) {
        let sender = ctx.sender();
        assert!(agreement.arbiter != @0x0, ENoArbiter);
        assert!(sender == agreement.arbiter, ENotArbiter);
        assert!(
            agreement.state == STATE_ACTIVE || agreement.state == STATE_DISPUTED,
            EInvalidState,
        );
        finalize_cancel(agreement, sender);
    }

    // ═══════════════════════════════════════════════════════════════════
    // Protocol Registry — Permissionless Outcome Recording
    // ═══════════════════════════════════════════════════════════════════

    /// Record a finalized agreement's outcome in the protocol registry.
    ///
    /// Permissionless — any address (indexer, bot, party, integrator) can call.
    /// Uses the finalized Agreement as cryptographic proof of its own outcome.
    /// Each agreement records exactly once: the registry_recorded flag prevents
    /// double-counting. The caller pays gas; no trust in the caller is required.
    ///
    /// This drives the on-chain statistics that integrators and dashboards read.
    /// Record a finalized agreement's outcome in the global registry.
    ///
    /// This function is OPTIONAL. Settlement, cancellation, and fund claims
    /// all work without ever calling this. It exists purely for on-chain stats.
    ///
    /// IMPORTANT — do NOT call this inside your user-facing settlement flow.
    /// PactaRegistry is a single shared object. At high volume, many apps
    /// writing to it simultaneously creates a queue that slows down the caller.
    /// Instead, call it in a separate background transaction after funds are
    /// already claimed — the user never waits for it.
    ///
    /// Each agreement can only be recorded once (EAlreadyRecorded on retry).
    public fun record_outcome(
        agreement: &mut Agreement,
        registry: &mut PactaRegistry,
    ) {
        assert!(!agreement.registry_recorded, EAlreadyRecorded);
        assert!(is_finalized(agreement), EInvalidState);
        if (agreement.state == STATE_SETTLED || agreement.state == STATE_DISPUTE_RESOLVED) {
            registry.total_settled = registry.total_settled + 1;
        } else {
            // STATE_CANCELLED
            registry.total_cancelled = registry.total_cancelled + 1;
        };
        agreement.registry_recorded = true;
    }

    // ═══════════════════════════════════════════════════════════════════
    // Claims
    // ═══════════════════════════════════════════════════════════════════

    /// Claim a coin deposit after finalization. Returns Coin<T> to the caller.
    ///
    /// source_party: PARTY_A (0) or PARTY_B (1) — whose escrowed deposit to claim.
    ///
    /// Routing set at finalization time:
    ///   Settled: cross-delivery (each party claims the other's deposit)
    ///   Cancelled: self-refund (each party claims their own deposit)
    ///   Dispute winner-takes-all: winner's address is the recipient for both sides
    public fun claim_coin<T>(
        agreement: &mut Agreement,
        source_party: u8,
        clock: &Clock,
        ctx: &mut TxContext,
    ): Coin<T> {
        let sender = ctx.sender();
        assert!(
            agreement.state == STATE_SETTLED || agreement.state == STATE_CANCELLED,
            EInvalidState,
        );
        if (agreement.unlock_time_ms > 0) {
            assert!(clock.timestamp_ms() >= agreement.unlock_time_ms, EUnlockTimeNotReached);
        };

        let recipient = if (source_party == PARTY_A) { agreement.a_recipient }
                        else { agreement.b_recipient };
        assert!(sender == recipient, ENotRecipient);

        let key = CoinEscrow<T> { party: source_party };
        assert!(df::exists_(&agreement.id, key), EDepositNotFound);
        let balance: Balance<T> = df::remove(&mut agreement.id, key);
        let amount = balance.value();
        agreement.active_slots = agreement.active_slots - 1;

        event::emit(CoinClaimed {
            agreement_id: object::id(agreement),
            claimed_by: sender,
            source_party,
            amount,
        });

        coin::from_balance(balance, ctx)
    }

    entry fun claim_coin_to_sender<T>(
        agreement: &mut Agreement,
        source_party: u8,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        let c = claim_coin<T>(agreement, source_party, clock, ctx);
        transfer::public_transfer(c, ctx.sender());
    }

    /// Claim an object deposit after finalization. Returns the object.
    public fun claim_object<V: key + store>(
        agreement: &mut Agreement,
        source_party: u8,
        index: u64,
        clock: &Clock,
        ctx: &mut TxContext,
    ): V {
        let sender = ctx.sender();
        assert!(
            agreement.state == STATE_SETTLED || agreement.state == STATE_CANCELLED,
            EInvalidState,
        );
        if (agreement.unlock_time_ms > 0) {
            assert!(clock.timestamp_ms() >= agreement.unlock_time_ms, EUnlockTimeNotReached);
        };

        let recipient = if (source_party == PARTY_A) { agreement.a_recipient }
                        else { agreement.b_recipient };
        assert!(sender == recipient, ENotRecipient);

        let key = ObjectEscrow { party: source_party, index };
        assert!(dof::exists_(&agreement.id, key), EDepositNotFound);
        let obj: V = dof::remove(&mut agreement.id, key);
        let obj_id = object::id(&obj);
        agreement.active_slots = agreement.active_slots - 1;

        event::emit(ObjectClaimed {
            agreement_id: object::id(agreement),
            claimed_by: sender,
            source_party,
            object_id: obj_id,
        });

        obj
    }

    entry fun claim_object_to_sender<V: key + store>(
        agreement: &mut Agreement,
        source_party: u8,
        index: u64,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        let obj = claim_object<V>(agreement, source_party, index, clock, ctx);
        transfer::public_transfer(obj, ctx.sender());
    }

    // ═══════════════════════════════════════════════════════════════════
    // Composability API — Raw Extraction for Protocol Integrations
    // ═══════════════════════════════════════════════════════════════════

    /// Extract raw Balance<T> from a finalized agreement.
    /// For wrapper contracts that route funds programmatically (DEX pools, vaults).
    /// Security: ctx.sender() must equal the designated recipient for source_party.
    public fun extract_coin_balance<T>(
        agreement: &mut Agreement,
        source_party: u8,
        clock: &Clock,
        ctx: &mut TxContext,
    ): Balance<T> {
        assert!(
            agreement.state == STATE_SETTLED || agreement.state == STATE_CANCELLED,
            EInvalidState,
        );
        if (agreement.unlock_time_ms > 0) {
            assert!(clock.timestamp_ms() >= agreement.unlock_time_ms, EUnlockTimeNotReached);
        };

        let recipient = if (source_party == PARTY_A) { agreement.a_recipient }
                        else { agreement.b_recipient };
        assert!(ctx.sender() == recipient, ENotRecipient);

        let key = CoinEscrow<T> { party: source_party };
        assert!(df::exists_(&agreement.id, key), EDepositNotFound);
        let bal = df::remove(&mut agreement.id, key);
        agreement.active_slots = agreement.active_slots - 1;
        bal
    }

    /// Extract an object for programmatic routing.
    /// Security: ctx.sender() must be the designated recipient.
    public fun extract_object<V: key + store>(
        agreement: &mut Agreement,
        source_party: u8,
        index: u64,
        clock: &Clock,
        ctx: &mut TxContext,
    ): V {
        assert!(
            agreement.state == STATE_SETTLED || agreement.state == STATE_CANCELLED,
            EInvalidState,
        );
        if (agreement.unlock_time_ms > 0) {
            assert!(clock.timestamp_ms() >= agreement.unlock_time_ms, EUnlockTimeNotReached);
        };

        let recipient = if (source_party == PARTY_A) { agreement.a_recipient }
                        else { agreement.b_recipient };
        assert!(ctx.sender() == recipient, ENotRecipient);

        let key = ObjectEscrow { party: source_party, index };
        assert!(dof::exists_(&agreement.id, key), EDepositNotFound);
        let obj = dof::remove(&mut agreement.id, key);
        agreement.active_slots = agreement.active_slots - 1;
        obj
    }

    // ═══════════════════════════════════════════════════════════════════
    // Settlement Hooks — Generic Callback Object System
    // ═══════════════════════════════════════════════════════════════════

    /// Attach any key+store object as a settlement hook.
    ///
    /// External protocols store execution context alongside the agreement.
    /// One hook slot per agreement. After settlement, call extract_hook()
    /// to retrieve the context and execute follow-up logic.
    ///
    /// Only parties or the creator can attach hooks.
    public fun attach_hook<H: key + store>(
        agreement: &mut Agreement,
        hook: H,
        ctx: &mut TxContext,
    ) {
        let sender = ctx.sender();
        assert!(
            sender == agreement.party_a
                || sender == agreement.party_b
                || sender == agreement.creator,
            ENotAuthorized,
        );
        assert!(!agreement.hook_attached, EAlreadyHookAttached);

        dof::add(&mut agreement.id, HookKey {}, hook);
        agreement.hook_attached = true;
        event::emit(HookAttached { agreement_id: object::id(agreement), attached_by: sender });
    }

    /// Extract the hook object after finalization. Returns it for the caller to process.
    /// Only parties or the creator can extract hooks.
    public fun extract_hook<H: key + store>(
        agreement: &mut Agreement,
        ctx: &mut TxContext,
    ): H {
        let sender = ctx.sender();
        assert!(
            sender == agreement.party_a
                || sender == agreement.party_b
                || sender == agreement.creator,
            ENotAuthorized,
        );
        assert!(is_finalized(agreement), EInvalidState);
        assert!(agreement.hook_attached, ENoHookAttached);

        agreement.hook_attached = false;
        dof::remove(&mut agreement.id, HookKey {})
    }

    /// Extract the hook object using a SettlementReceipt as authorization proof.
    ///
    /// The receipt cryptographically proves that:
    ///   1. Settlement occurred for a specific agreement_id.
    ///   2. The caller produced the receipt in this same PTB via settle_with_receipt().
    ///
    /// This enables executor/bot patterns: the executor calls settle_with_receipt(),
    /// receives the receipt, and passes it here as proof — without being a party.
    /// The receipt is taken by immutable reference so it can still be consumed
    /// afterward by consume_settlement_receipt().
    ///
    /// Call order in PTB:
    ///   1. let receipt = settle_with_receipt(agreement, clock, ctx)
    ///   2. let hook    = extract_hook_with_receipt<H>(agreement, &receipt)
    ///   3. consume_settlement_receipt(receipt)   ← consume last
    public fun extract_hook_with_receipt<H: key + store>(
        agreement: &mut Agreement,
        receipt: &SettlementReceipt,
    ): H {
        assert!(receipt.agreement_id == object::id(agreement), EInvalidAgreement);
        assert!(is_finalized(agreement), EInvalidState);
        assert!(agreement.hook_attached, ENoHookAttached);
        agreement.hook_attached = false;
        dof::remove(&mut agreement.id, HookKey {})
    }

    // ═══════════════════════════════════════════════════════════════════
    // Deposit Existence Checks
    // ═══════════════════════════════════════════════════════════════════

    public fun has_coin_deposit<T>(agreement: &Agreement, party: u8): bool {
        df::exists_(&agreement.id, CoinEscrow<T> { party })
    }

    public fun has_object_deposit(agreement: &Agreement, party: u8, index: u64): bool {
        dof::exists_(&agreement.id, ObjectEscrow { party, index })
    }

    // ═══════════════════════════════════════════════════════════════════
    // AdminCap Governance
    // ═══════════════════════════════════════════════════════════════════

    /// Transfer AdminCap to a new address — typically a Sui multisig wallet.
    ///
    /// This is a one-way operation in the sense that the current holder loses
    /// all admin privileges immediately. Verify the recipient address carefully
    /// before calling — there is no recovery if transferred to a wrong address.
    ///
    /// Recommended governance setup at deploy time:
    ///   1. Create a 3-of-5 Sui multisig address from the team's hardware wallets.
    ///   2. Call transfer_admin_cap(cap, multisig_address) to hand over control.
    ///   3. Call timelock::transfer_admin(tl_cap, multisig_address) to do the same
    ///      for the upgrade timelock, so both keys are held by the same multisig.
    ///
    /// See GOVERNANCE.md for the full step-by-step deployment checklist.
    public entry fun transfer_admin_cap(cap: AdminCap, recipient: address) {
        transfer::transfer(cap, recipient);
    }

    // ═══════════════════════════════════════════════════════════════════
    // Registry — Admin Operations
    // ═══════════════════════════════════════════════════════════════════

    public fun record_settled(_: &AdminCap, r: &mut PactaRegistry) {
        r.total_settled = r.total_settled + 1;
    }
    public fun record_cancelled(_: &AdminCap, r: &mut PactaRegistry) {
        r.total_cancelled = r.total_cancelled + 1;
    }
    public fun record_disputed(_: &AdminCap, r: &mut PactaRegistry) {
        r.total_disputed = r.total_disputed + 1;
    }

    // ═══════════════════════════════════════════════════════════════════
    // Read Accessors
    // ═══════════════════════════════════════════════════════════════════

    public fun get_version(a: &Agreement): u64           { a.version }
    public fun get_creator(a: &Agreement): address       { a.creator }
    public fun get_party_a(a: &Agreement): address       { a.party_a }
    public fun get_party_b(a: &Agreement): address       { a.party_b }
    public fun get_arbiter(a: &Agreement): address       { a.arbiter }
    public fun get_state(a: &Agreement): u8              { a.state }
    public fun get_release_conditions(a: &Agreement): u8 { a.release_conditions }
    public fun get_a_deposited(a: &Agreement): bool      { a.a_deposited }
    public fun get_b_deposited(a: &Agreement): bool      { a.b_deposited }
    public fun get_a_approved(a: &Agreement): bool       { a.a_approved }
    public fun get_b_approved(a: &Agreement): bool       { a.b_approved }
    public fun get_a_obj_count(a: &Agreement): u64       { a.a_obj_count }
    public fun get_b_obj_count(a: &Agreement): u64       { a.b_obj_count }
    public fun get_active_slots(a: &Agreement): u64      { a.active_slots }
    public fun get_hook_attached(a: &Agreement): bool      { a.hook_attached }
    public fun get_registry_recorded(a: &Agreement): bool  { a.registry_recorded }
    public fun get_a_recipient(a: &Agreement): address     { a.a_recipient }
    public fun get_b_recipient(a: &Agreement): address   { a.b_recipient }
    public fun get_terms_hash(a: &Agreement): vector<u8> { a.terms_hash }
    public fun get_expiry_ms(a: &Agreement): u64         { a.expiry_ms }
    public fun get_unlock_time_ms(a: &Agreement): u64    { a.unlock_time_ms }
    public fun get_created_at_ms(a: &Agreement): u64     { a.created_at_ms }
    public fun get_settled_at_ms(a: &Agreement): u64     { a.settled_at_ms }
    public fun get_metadata(a: &Agreement): vector<u8>   { a.metadata }

    // v2-compatible aliases
    public fun creator(a: &Agreement): address           { a.creator }
    public fun party_a(a: &Agreement): address           { a.party_a }
    public fun party_b(a: &Agreement): address           { a.party_b }
    public fun arbiter(a: &Agreement): address           { a.arbiter }
    public fun state(a: &Agreement): u8                  { a.state }
    public fun release_conditions(a: &Agreement): u8     { a.release_conditions }
    public fun a_deposited(a: &Agreement): bool          { a.a_deposited }
    public fun b_deposited(a: &Agreement): bool          { a.b_deposited }
    public fun a_approved(a: &Agreement): bool           { a.a_approved }
    public fun b_approved(a: &Agreement): bool           { a.b_approved }
    public fun a_cancel_consent(a: &Agreement): bool     { a.a_cancel_consent }
    public fun b_cancel_consent(a: &Agreement): bool     { a.b_cancel_consent }
    public fun registry_recorded(a: &Agreement): bool    { a.registry_recorded }
    public fun a_obj_count(a: &Agreement): u64           { a.a_obj_count }
    public fun b_obj_count(a: &Agreement): u64           { a.b_obj_count }
    public fun a_recipient(a: &Agreement): address       { a.a_recipient }
    public fun b_recipient(a: &Agreement): address       { a.b_recipient }
    public fun terms_hash(a: &Agreement): vector<u8>     { a.terms_hash }
    public fun expiry_ms(a: &Agreement): u64             { a.expiry_ms }
    public fun unlock_time_ms(a: &Agreement): u64        { a.unlock_time_ms }
    public fun created_at_ms(a: &Agreement): u64         { a.created_at_ms }
    public fun metadata(a: &Agreement): vector<u8>       { a.metadata }

    // State predicates
    public fun is_created(a: &Agreement): bool           { a.state == STATE_CREATED }
    public fun is_active(a: &Agreement): bool            { a.state == STATE_ACTIVE }
    public fun is_settled(a: &Agreement): bool           { a.state == STATE_SETTLED }
    public fun is_cancelled(a: &Agreement): bool         { a.state == STATE_CANCELLED }
    public fun is_disputed(a: &Agreement): bool          { a.state == STATE_DISPUTED }
    public fun is_dispute_resolved(a: &Agreement): bool  { a.state == STATE_DISPUTE_RESOLVED }

    /// True if agreement is in any terminal state (no further transitions).
    public fun is_finalized(a: &Agreement): bool {
        let s = a.state;
        s == STATE_SETTLED || s == STATE_CANCELLED || s == STATE_DISPUTE_RESOLVED
    }

    /// True if all escrow slots are empty and no hook is attached.
    ///
    /// This is the pre-condition for destroy(). Wrapper protocols that hold
    /// an Agreement by value inside their own struct should call this before
    /// calling destroy() to avoid an abort on the active_slots check.
    ///
    /// Example:
    ///   assert!(pacta::is_drained(&ag), ENotReady);
    ///   pacta::destroy(ag);
    public fun is_drained(a: &Agreement): bool {
        a.active_slots == 0 && !a.hook_attached
    }

    public fun both_deposited(a: &Agreement): bool { a.a_deposited && a.b_deposited }
    public fun both_approved(a: &Agreement): bool  { a.a_approved && a.b_approved }

    // Condition flag constants for external module use
    public fun cond_a_deposited(): u8  { COND_A_DEPOSITED }
    public fun cond_b_deposited(): u8  { COND_B_DEPOSITED }
    public fun cond_a_approved(): u8   { COND_A_APPROVED }
    public fun cond_b_approved(): u8   { COND_B_APPROVED }
    public fun cond_timelock(): u8     { COND_TIMELOCK }
    public fun party_a_id(): u8        { PARTY_A }
    public fun party_b_id(): u8        { PARTY_B }
    public fun protocol_version(): u64 { VERSION }

    // Registry accessors
    public fun registry_version(r: &PactaRegistry): u64  { r.version }
    public fun total_agreements(r: &PactaRegistry): u64  { r.total_agreements }
    public fun total_settled(r: &PactaRegistry): u64     { r.total_settled }
    public fun total_cancelled(r: &PactaRegistry): u64   { r.total_cancelled }
    public fun total_disputed(r: &PactaRegistry): u64    { r.total_disputed }

    // Receipt read accessors (non-consuming)
    public fun receipt_agreement_id(r: &SettlementReceipt): ID     { r.agreement_id }
    public fun receipt_a_recipient(r: &SettlementReceipt): address { r.a_recipient }
    public fun receipt_b_recipient(r: &SettlementReceipt): address { r.b_recipient }
    public fun receipt_settled_at_ms(r: &SettlementReceipt): u64   { r.settled_at_ms }

    // ═══════════════════════════════════════════════════════════════════
    // Internal Helpers
    // ═══════════════════════════════════════════════════════════════════

    fun resolve_party(agreement: &Agreement, sender: address): u8 {
        if (sender == agreement.party_a)      { PARTY_A }
        else if (sender == agreement.party_b) { PARTY_B }
        else                                  { abort ENotParty }
    }

    // ═══════════════════════════════════════════════════════════════════
    // Destroy — Safe Cleanup After Full Drainage
    // ═══════════════════════════════════════════════════════════════════

    /// Destroy a fully-drained, finalized Agreement taken by value.
    ///
    /// ┌─ WHICH AGREEMENTS CAN BE DESTROYED? ──────────────────────────────┐
    /// │                                                                    │
    /// │  OWNED / WRAPPED (created via create_agreement)                   │
    /// │    The caller holds the Agreement by value, or wrapped inside      │
    /// │    their own struct (possible because Agreement has `store`).      │
    /// │    destroy() works correctly here — call is_drained() first.      │
    /// │                                                                    │
    /// │  SHARED (created via create_and_share / create_share_and_record)  │
    /// │    After transfer::share_object(), Sui's runtime permanently       │
    /// │    forbids taking the object by value. destroy() is therefore      │
    /// │    unreachable for shared Agreements in any real transaction.      │
    /// │    Shared Agreements remain on-chain as permanent records.        │
    /// │                                                                    │
    /// └────────────────────────────────────────────────────────────────────┘
    ///
    /// Three guards prevent accidental fund loss:
    ///   1. State must be terminal (SETTLED, CANCELLED, or DISPUTE_RESOLVED).
    ///   2. active_slots must be 0 — all coin and object escrow entries must
    ///      be claimed/extracted/distributed before this can succeed.
    ///   3. hook_attached must be false — extract the hook object first.
    ///
    /// Call is_drained() to check guards 2 & 3 before calling destroy().
    public fun destroy(agreement: Agreement) {
        let Agreement { id, state, active_slots, hook_attached, .. } = agreement;
        assert!(
            state == STATE_SETTLED
                || state == STATE_CANCELLED
                || state == STATE_DISPUTE_RESOLVED,
            EInvalidState,
        );
        assert!(active_slots == 0, EHasUnclaimedAssets);
        assert!(!hook_attached, EHasUnclaimedAssets);
        object::delete(id);
    }

    // ═══════════════════════════════════════════════════════════════════
    // Test Helpers
    // ═══════════════════════════════════════════════════════════════════

    #[test_only]
    public fun init_for_testing(ctx: &mut TxContext) {
        init(ctx);
    }
}
