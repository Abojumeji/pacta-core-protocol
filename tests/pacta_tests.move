/// Pacta Core Protocol v4 — Test Suite
///
/// Coverage:
///   GROUP  1 — Agreement creation and field correctness
///   GROUP  2 — Auto-settle: COND_A_DEPOSITED | COND_B_DEPOSITED
///   GROUP  3 — Claim routing: cross-delivery after settlement
///   GROUP  4 — Claim routing: self-refund after cancellation
///   GROUP  5 — Unauthorised claim rejected (ENotRecipient)
///   GROUP  6 — Unilateral cancel guards
///   GROUP  7 — Mutual cancel (cooperative unwind)
///   GROUP  8 — Permissionless cancel_expired
///   GROUP  9 — Approval-based settlement (COND_A_APPROVED | COND_B_APPROVED)
///   GROUP 10 — active_slots tracking (deposit increments, claim decrements)
///   GROUP 11 — destroy() safety guards (EHasUnclaimedAssets, EInvalidState)
///   GROUP 12 — Arbiter functions (arbiter_settle, arbiter_cancel)
///   GROUP 13 — Dispute lifecycle (raise → resolve → conclude)
///   GROUP 14 — record_outcome and double-recording prevention
///   GROUP 15 — set_party_b open-listing pattern
///   GROUP 16 — Non-party deposit rejected (ENotParty)
///   GROUP 17 — is_ready_to_settle reflects live condition state
///   GROUP 18 — Protocol version constant
#[test_only]
module pacta::pacta_tests {
    use pacta::pacta::{
        Self,
        Agreement,
        PactaRegistry,
    };
    use sui::coin::{Self, Coin};
    use sui::balance;
    use sui::test_scenario::{Self as ts};
    use sui::clock::{Self, Clock};
    use sui::test_utils;

    // ─── Dummy coin type for tests ────────────────────────────────────────────
    public struct TUSDC has drop {}

    // ─── Test addresses ───────────────────────────────────────────────────────
    const DEPLOYER:    address = @0x1111;
    const ADDR_A:      address = @0xAAAA;
    const ADDR_B:      address = @0xBBBB;
    const ADDR_ARB:    address = @0xCCCC;
    const ADDR_EXEC:   address = @0xEEEE;
    const ADDR_RANDO:  address = @0xDEAD;

    // ─── Helpers ──────────────────────────────────────────────────────────────

    fun mint(amount: u64, ctx: &mut TxContext): Coin<TUSDC> {
        coin::from_balance(balance::create_for_testing<TUSDC>(amount), ctx)
    }

    /// Create a standard atomic-swap agreement (COND_A_DEPOSITED | COND_B_DEPOSITED).
    fun make_swap_agreement(clock: &Clock, ctx: &mut TxContext): Agreement {
        pacta::create_agreement(
            ADDR_A, ADDR_B, @0x0,
            pacta::cond_a_deposited() | pacta::cond_b_deposited(),
            b"test-terms", 0, 0, b"",
            clock, ctx,
        )
    }

    /// Create an agreement that requires both deposits AND party-A approval.
    /// The extra COND_A_APPROVED flag prevents auto-settle after both deposit,
    /// which lets tests inspect the state between deposits.
    fun make_three_cond_agreement(clock: &Clock, ctx: &mut TxContext): Agreement {
        pacta::create_agreement(
            ADDR_A, ADDR_B, @0x0,
            pacta::cond_a_deposited() | pacta::cond_b_deposited() | pacta::cond_a_approved(),
            b"test-terms", 0, 0, b"",
            clock, ctx,
        )
    }

    /// Create an arbiter-only agreement (release_conditions = 0, no auto-settle).
    fun make_arbiter_agreement(clock: &Clock, ctx: &mut TxContext): Agreement {
        pacta::create_agreement(
            ADDR_A, ADDR_B, ADDR_ARB,
            0,
            b"test-terms", 0, 0, b"",
            clock, ctx,
        )
    }

    // ─── GROUP 1: Agreement creation ─────────────────────────────────────────

    #[test]
    fun test_create_agreement_initial_fields() {
        let mut scenario = ts::begin(ADDR_A);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));

        let ag = pacta::create_agreement(
            ADDR_A, ADDR_B, ADDR_ARB,
            pacta::cond_a_deposited() | pacta::cond_b_deposited(),
            b"my-terms", 0, 0, b"meta",
            &clock, ts::ctx(&mut scenario),
        );

        assert!(pacta::get_party_a(&ag) == ADDR_A);
        assert!(pacta::get_party_b(&ag) == ADDR_B);
        assert!(pacta::get_arbiter(&ag) == ADDR_ARB);
        assert!(pacta::is_created(&ag));
        assert!(!pacta::is_active(&ag));
        assert!(!pacta::is_settled(&ag));
        assert!(!pacta::is_cancelled(&ag));
        assert!(pacta::get_active_slots(&ag) == 0);
        assert!(!pacta::get_a_deposited(&ag));
        assert!(!pacta::get_b_deposited(&ag));
        assert!(!pacta::get_a_approved(&ag));
        assert!(!pacta::get_b_approved(&ag));
        assert!(!pacta::get_hook_attached(&ag));
        assert!(!pacta::registry_recorded(&ag));
        assert!(pacta::get_release_conditions(&ag) == 3); // COND_A_DEPOSITED | COND_B_DEPOSITED

        clock::destroy_for_testing(clock);
        test_utils::destroy(ag);
        ts::end(scenario);
    }

    // ─── GROUP 2: Auto-settle on second deposit ───────────────────────────────

    #[test]
    fun test_auto_settle_fires_after_both_deposit() {
        let mut scenario = ts::begin(ADDR_A);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));

        let ag = make_swap_agreement(&clock, ts::ctx(&mut scenario));
        transfer::public_share_object(ag);

        // A deposits → ACTIVE, not yet settled
        ts::next_tx(&mut scenario, ADDR_A);
        {
            let mut ag = ts::take_shared<Agreement>(&scenario);
            let c = mint(1_000, ts::ctx(&mut scenario));
            pacta::deposit_coin<TUSDC>(&mut ag, c, &clock, ts::ctx(&mut scenario));
            assert!(pacta::is_active(&ag));
            assert!(pacta::get_a_deposited(&ag));
            assert!(!pacta::is_settled(&ag));
            ts::return_shared(ag);
        };

        // B deposits → conditions met → auto-settle fires
        ts::next_tx(&mut scenario, ADDR_B);
        {
            let mut ag = ts::take_shared<Agreement>(&scenario);
            let c = mint(2_000, ts::ctx(&mut scenario));
            pacta::deposit_coin<TUSDC>(&mut ag, c, &clock, ts::ctx(&mut scenario));
            assert!(pacta::is_settled(&ag));
            assert!(pacta::get_b_deposited(&ag));
            ts::return_shared(ag);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    // ─── GROUP 3: Cross-delivery routing after settlement ────────────────────

    #[test]
    fun test_claim_routing_cross_delivery_after_settle() {
        let mut scenario = ts::begin(ADDR_A);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));

        let ag = make_swap_agreement(&clock, ts::ctx(&mut scenario));
        transfer::public_share_object(ag);

        // A deposits 1_000
        ts::next_tx(&mut scenario, ADDR_A);
        {
            let mut ag = ts::take_shared<Agreement>(&scenario);
            pacta::deposit_coin<TUSDC>(&mut ag, mint(1_000, ts::ctx(&mut scenario)), &clock, ts::ctx(&mut scenario));
            ts::return_shared(ag);
        };

        // B deposits 2_000 → auto-settle: a_recipient=B, b_recipient=A
        ts::next_tx(&mut scenario, ADDR_B);
        {
            let mut ag = ts::take_shared<Agreement>(&scenario);
            pacta::deposit_coin<TUSDC>(&mut ag, mint(2_000, ts::ctx(&mut scenario)), &clock, ts::ctx(&mut scenario));
            assert!(pacta::get_a_recipient(&ag) == ADDR_B); // cross-delivery
            assert!(pacta::get_b_recipient(&ag) == ADDR_A);
            ts::return_shared(ag);
        };

        // B (a_recipient) claims A's 1_000 slot
        ts::next_tx(&mut scenario, ADDR_B);
        {
            let mut ag = ts::take_shared<Agreement>(&scenario);
            let coin = pacta::claim_coin<TUSDC>(&mut ag, pacta::party_a_id(), &clock, ts::ctx(&mut scenario));
            assert!(coin.value() == 1_000);
            transfer::public_transfer(coin, ADDR_B);
            ts::return_shared(ag);
        };

        // A (b_recipient) claims B's 2_000 slot
        ts::next_tx(&mut scenario, ADDR_A);
        {
            let mut ag = ts::take_shared<Agreement>(&scenario);
            let coin = pacta::claim_coin<TUSDC>(&mut ag, pacta::party_b_id(), &clock, ts::ctx(&mut scenario));
            assert!(coin.value() == 2_000);
            assert!(pacta::get_active_slots(&ag) == 0);
            transfer::public_transfer(coin, ADDR_A);
            ts::return_shared(ag);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    // ─── GROUP 4: Self-refund routing after cancellation ─────────────────────

    #[test]
    fun test_claim_routing_self_refund_after_cancel() {
        let mut scenario = ts::begin(ADDR_A);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));

        let ag = make_swap_agreement(&clock, ts::ctx(&mut scenario));
        transfer::public_share_object(ag);

        // Only A deposits 500
        ts::next_tx(&mut scenario, ADDR_A);
        {
            let mut ag = ts::take_shared<Agreement>(&scenario);
            pacta::deposit_coin<TUSDC>(&mut ag, mint(500, ts::ctx(&mut scenario)), &clock, ts::ctx(&mut scenario));
            ts::return_shared(ag);
        };

        // A cancels (only one deposited, allowed)
        ts::next_tx(&mut scenario, ADDR_A);
        {
            let mut ag = ts::take_shared<Agreement>(&scenario);
            pacta::cancel(&mut ag, ts::ctx(&mut scenario));
            assert!(pacta::is_cancelled(&ag));
            // Self-refund: a_recipient = party_a
            assert!(pacta::get_a_recipient(&ag) == ADDR_A);
            assert!(pacta::get_b_recipient(&ag) == ADDR_B);
            ts::return_shared(ag);
        };

        // A reclaims own 500
        ts::next_tx(&mut scenario, ADDR_A);
        {
            let mut ag = ts::take_shared<Agreement>(&scenario);
            let coin = pacta::claim_coin<TUSDC>(&mut ag, pacta::party_a_id(), &clock, ts::ctx(&mut scenario));
            assert!(coin.value() == 500);
            assert!(pacta::get_active_slots(&ag) == 0);
            transfer::public_transfer(coin, ADDR_A);
            ts::return_shared(ag);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    // ─── GROUP 5: Unauthorised claim rejected ─────────────────────────────────

    #[test]
    #[expected_failure(abort_code = 8)]  // ENotRecipient
    fun test_wrong_address_cannot_claim() {
        let mut scenario = ts::begin(ADDR_A);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));

        let ag = make_swap_agreement(&clock, ts::ctx(&mut scenario));
        transfer::public_share_object(ag);

        ts::next_tx(&mut scenario, ADDR_A);
        {
            let mut ag = ts::take_shared<Agreement>(&scenario);
            pacta::deposit_coin<TUSDC>(&mut ag, mint(100, ts::ctx(&mut scenario)), &clock, ts::ctx(&mut scenario));
            ts::return_shared(ag);
        };

        ts::next_tx(&mut scenario, ADDR_B);
        {
            let mut ag = ts::take_shared<Agreement>(&scenario);
            pacta::deposit_coin<TUSDC>(&mut ag, mint(200, ts::ctx(&mut scenario)), &clock, ts::ctx(&mut scenario));
            ts::return_shared(ag);
        };

        // ADDR_RANDO is not a_recipient (which is ADDR_B after cross-delivery)
        ts::next_tx(&mut scenario, ADDR_RANDO);
        {
            let mut ag = ts::take_shared<Agreement>(&scenario);
            let coin = pacta::claim_coin<TUSDC>(&mut ag, pacta::party_a_id(), &clock, ts::ctx(&mut scenario));
            transfer::public_transfer(coin, ADDR_RANDO); // unreachable
            ts::return_shared(ag);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    // ─── GROUP 6: Unilateral cancel guards ───────────────────────────────────

    #[test]
    fun test_cancel_in_created_state_by_creator() {
        let mut scenario = ts::begin(ADDR_A);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));

        // No deposit → still in CREATED; creator can cancel
        let mut ag = make_swap_agreement(&clock, ts::ctx(&mut scenario));
        pacta::cancel(&mut ag, ts::ctx(&mut scenario));
        assert!(pacta::is_cancelled(&ag));

        clock::destroy_for_testing(clock);
        test_utils::destroy(ag);
        ts::end(scenario);
    }

    #[test]
    fun test_cancel_active_one_deposited() {
        let mut scenario = ts::begin(ADDR_A);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));

        let ag = make_swap_agreement(&clock, ts::ctx(&mut scenario));
        transfer::public_share_object(ag);

        ts::next_tx(&mut scenario, ADDR_A);
        {
            let mut ag = ts::take_shared<Agreement>(&scenario);
            pacta::deposit_coin<TUSDC>(&mut ag, mint(100, ts::ctx(&mut scenario)), &clock, ts::ctx(&mut scenario));
            // Only A deposited → A may cancel
            pacta::cancel(&mut ag, ts::ctx(&mut scenario));
            assert!(pacta::is_cancelled(&ag));
            ts::return_shared(ag);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = 13)]  // ECannotCancelBothDeposited
    fun test_unilateral_cancel_blocked_when_both_deposited() {
        let mut scenario = ts::begin(ADDR_A);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));

        // Three-condition agreement so deposits don't auto-settle
        let ag = make_three_cond_agreement(&clock, ts::ctx(&mut scenario));
        transfer::public_share_object(ag);

        ts::next_tx(&mut scenario, ADDR_A);
        {
            let mut ag = ts::take_shared<Agreement>(&scenario);
            pacta::deposit_coin<TUSDC>(&mut ag, mint(100, ts::ctx(&mut scenario)), &clock, ts::ctx(&mut scenario));
            ts::return_shared(ag);
        };

        ts::next_tx(&mut scenario, ADDR_B);
        {
            let mut ag = ts::take_shared<Agreement>(&scenario);
            pacta::deposit_coin<TUSDC>(&mut ag, mint(200, ts::ctx(&mut scenario)), &clock, ts::ctx(&mut scenario));
            ts::return_shared(ag);
        };

        // Both deposited; A tries to cancel unilaterally → ECannotCancelBothDeposited
        ts::next_tx(&mut scenario, ADDR_A);
        {
            let mut ag = ts::take_shared<Agreement>(&scenario);
            pacta::cancel(&mut ag, ts::ctx(&mut scenario));
            ts::return_shared(ag);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    // ─── GROUP 7: Mutual cancel ───────────────────────────────────────────────

    #[test]
    fun test_mutual_cancel_requires_both_consents() {
        let mut scenario = ts::begin(ADDR_A);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));

        let ag = make_three_cond_agreement(&clock, ts::ctx(&mut scenario));
        transfer::public_share_object(ag);

        ts::next_tx(&mut scenario, ADDR_A);
        {
            let mut ag = ts::take_shared<Agreement>(&scenario);
            pacta::deposit_coin<TUSDC>(&mut ag, mint(100, ts::ctx(&mut scenario)), &clock, ts::ctx(&mut scenario));
            ts::return_shared(ag);
        };

        ts::next_tx(&mut scenario, ADDR_B);
        {
            let mut ag = ts::take_shared<Agreement>(&scenario);
            pacta::deposit_coin<TUSDC>(&mut ag, mint(200, ts::ctx(&mut scenario)), &clock, ts::ctx(&mut scenario));
            ts::return_shared(ag);
        };

        // A signals consent — not yet cancelled
        ts::next_tx(&mut scenario, ADDR_A);
        {
            let mut ag = ts::take_shared<Agreement>(&scenario);
            pacta::mutual_cancel(&mut ag, ts::ctx(&mut scenario));
            assert!(pacta::a_cancel_consent(&ag));
            assert!(!pacta::is_cancelled(&ag));
            ts::return_shared(ag);
        };

        // B signals consent → cancellation fires
        ts::next_tx(&mut scenario, ADDR_B);
        {
            let mut ag = ts::take_shared<Agreement>(&scenario);
            pacta::mutual_cancel(&mut ag, ts::ctx(&mut scenario));
            assert!(pacta::is_cancelled(&ag));
            assert!(pacta::get_a_recipient(&ag) == ADDR_A); // self-refund
            assert!(pacta::get_b_recipient(&ag) == ADDR_B);
            ts::return_shared(ag);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    // ─── GROUP 8: Permissionless cancel_expired ───────────────────────────────

    #[test]
    fun test_cancel_expired_permissionless() {
        let mut scenario = ts::begin(ADDR_A);
        let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));

        // Agreement with expiry_ms = 1_000
        let ag = pacta::create_agreement(
            ADDR_A, ADDR_B, @0x0,
            pacta::cond_a_deposited() | pacta::cond_b_deposited(),
            b"", 1_000, 0, b"",
            &clock, ts::ctx(&mut scenario),
        );
        transfer::public_share_object(ag);

        // A deposits before expiry
        ts::next_tx(&mut scenario, ADDR_A);
        {
            let mut ag = ts::take_shared<Agreement>(&scenario);
            pacta::deposit_coin<TUSDC>(&mut ag, mint(100, ts::ctx(&mut scenario)), &clock, ts::ctx(&mut scenario));
            ts::return_shared(ag);
        };

        // Advance clock past expiry
        clock::set_for_testing(&mut clock, 2_000);

        // Permissionless executor cancels the expired agreement
        ts::next_tx(&mut scenario, ADDR_EXEC);
        {
            let mut ag = ts::take_shared<Agreement>(&scenario);
            pacta::cancel_expired(&mut ag, &clock, ts::ctx(&mut scenario));
            assert!(pacta::is_cancelled(&ag));
            ts::return_shared(ag);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    // ─── GROUP 9: Approval-based settlement ──────────────────────────────────

    #[test]
    fun test_approval_based_settlement() {
        let mut scenario = ts::begin(ADDR_A);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));

        // Conditions: COND_A_APPROVED | COND_B_APPROVED only
        let ag = pacta::create_agreement(
            ADDR_A, ADDR_B, @0x0,
            pacta::cond_a_approved() | pacta::cond_b_approved(),
            b"", 0, 0, b"",
            &clock, ts::ctx(&mut scenario),
        );
        transfer::public_share_object(ag);

        // A deposits to move from CREATED → ACTIVE
        ts::next_tx(&mut scenario, ADDR_A);
        {
            let mut ag = ts::take_shared<Agreement>(&scenario);
            pacta::deposit_coin<TUSDC>(&mut ag, mint(100, ts::ctx(&mut scenario)), &clock, ts::ctx(&mut scenario));
            assert!(pacta::is_active(&ag));
            assert!(!pacta::is_settled(&ag)); // approvals not yet given
            ts::return_shared(ag);
        };

        // A approves — not settled yet (B hasn't approved)
        ts::next_tx(&mut scenario, ADDR_A);
        {
            let mut ag = ts::take_shared<Agreement>(&scenario);
            pacta::approve(&mut ag, &clock, ts::ctx(&mut scenario));
            assert!(pacta::get_a_approved(&ag));
            assert!(!pacta::is_settled(&ag));
            ts::return_shared(ag);
        };

        // B approves → COND_A_APPROVED | COND_B_APPROVED met → auto-settle
        ts::next_tx(&mut scenario, ADDR_B);
        {
            let mut ag = ts::take_shared<Agreement>(&scenario);
            pacta::approve(&mut ag, &clock, ts::ctx(&mut scenario));
            assert!(pacta::get_b_approved(&ag));
            assert!(pacta::is_settled(&ag));
            ts::return_shared(ag);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    // ─── GROUP 10: active_slots tracking ─────────────────────────────────────

    #[test]
    fun test_active_slots_increment_and_decrement() {
        let mut scenario = ts::begin(ADDR_A);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));

        let ag = make_swap_agreement(&clock, ts::ctx(&mut scenario));
        transfer::public_share_object(ag);

        ts::next_tx(&mut scenario, ADDR_A);
        {
            let mut ag = ts::take_shared<Agreement>(&scenario);
            assert!(pacta::get_active_slots(&ag) == 0);
            pacta::deposit_coin<TUSDC>(&mut ag, mint(100, ts::ctx(&mut scenario)), &clock, ts::ctx(&mut scenario));
            assert!(pacta::get_active_slots(&ag) == 1); // +1 on first deposit of a type
            ts::return_shared(ag);
        };

        ts::next_tx(&mut scenario, ADDR_B);
        {
            let mut ag = ts::take_shared<Agreement>(&scenario);
            pacta::deposit_coin<TUSDC>(&mut ag, mint(200, ts::ctx(&mut scenario)), &clock, ts::ctx(&mut scenario));
            assert!(pacta::get_active_slots(&ag) == 2); // +1 for B's slot (auto-settle also fired)
            ts::return_shared(ag);
        };

        // B (a_recipient) claims A's slot
        ts::next_tx(&mut scenario, ADDR_B);
        {
            let mut ag = ts::take_shared<Agreement>(&scenario);
            let c = pacta::claim_coin<TUSDC>(&mut ag, pacta::party_a_id(), &clock, ts::ctx(&mut scenario));
            assert!(pacta::get_active_slots(&ag) == 1); // -1
            transfer::public_transfer(c, ADDR_B);
            ts::return_shared(ag);
        };

        // A (b_recipient) claims B's slot
        ts::next_tx(&mut scenario, ADDR_A);
        {
            let mut ag = ts::take_shared<Agreement>(&scenario);
            let c = pacta::claim_coin<TUSDC>(&mut ag, pacta::party_b_id(), &clock, ts::ctx(&mut scenario));
            assert!(pacta::get_active_slots(&ag) == 0); // -1 → 0
            transfer::public_transfer(c, ADDR_A);
            ts::return_shared(ag);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    #[test]
    fun test_top_up_same_coin_type_does_not_open_new_slot() {
        let mut scenario = ts::begin(ADDR_A);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));

        // Three-condition so second B deposit won't auto-settle
        let ag = make_three_cond_agreement(&clock, ts::ctx(&mut scenario));
        transfer::public_share_object(ag);

        ts::next_tx(&mut scenario, ADDR_A);
        {
            let mut ag = ts::take_shared<Agreement>(&scenario);
            pacta::deposit_coin<TUSDC>(&mut ag, mint(100, ts::ctx(&mut scenario)), &clock, ts::ctx(&mut scenario));
            assert!(pacta::get_active_slots(&ag) == 1);
            // Second deposit of same coin type by same party: merges, no new slot
            pacta::deposit_coin<TUSDC>(&mut ag, mint(50, ts::ctx(&mut scenario)), &clock, ts::ctx(&mut scenario));
            assert!(pacta::get_active_slots(&ag) == 1); // still 1
            ts::return_shared(ag);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    // ─── GROUP 11: destroy() safety guards ───────────────────────────────────
    //
    // NOTE — Test vs Production discrepancy:
    //
    // These tests call ts::take_shared<Agreement>() which hands the Agreement
    // by value to the test code. This is a test framework convenience that
    // bypasses the real Sui object model.
    //
    // In production, once transfer::share_object() is called, the Sui runtime
    // permanently forbids taking that object by value. destroy() is therefore
    // unreachable for shared Agreements in any real PTB.
    //
    // These tests are still valid — they verify that the three safety guards
    // (terminal state, active_slots == 0, hook_attached == false) work
    // correctly in the owned/wrapped pattern where destroy() IS reachable.
    //
    // Shared Agreements created via create_and_share remain on-chain as
    // permanent records. Builders who need destroyable Agreements should
    // use create_agreement() and hold or wrap the object themselves.

    #[test]
    #[expected_failure(abort_code = 14)]  // EHasUnclaimedAssets
    fun test_destroy_blocked_with_unclaimed_assets() {
        let mut scenario = ts::begin(ADDR_A);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));

        let ag = make_swap_agreement(&clock, ts::ctx(&mut scenario));
        transfer::public_share_object(ag);

        ts::next_tx(&mut scenario, ADDR_A);
        {
            let mut ag = ts::take_shared<Agreement>(&scenario);
            pacta::deposit_coin<TUSDC>(&mut ag, mint(100, ts::ctx(&mut scenario)), &clock, ts::ctx(&mut scenario));
            ts::return_shared(ag);
        };

        ts::next_tx(&mut scenario, ADDR_B);
        {
            let mut ag = ts::take_shared<Agreement>(&scenario);
            pacta::deposit_coin<TUSDC>(&mut ag, mint(200, ts::ctx(&mut scenario)), &clock, ts::ctx(&mut scenario));
            // Settled but funds unclaimed — active_slots == 2
            pacta::destroy(ag); // must abort EHasUnclaimedAssets
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = 1)]  // EInvalidState
    fun test_destroy_blocked_in_active_state() {
        let mut scenario = ts::begin(ADDR_A);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));

        let ag = make_swap_agreement(&clock, ts::ctx(&mut scenario));
        transfer::public_share_object(ag);

        ts::next_tx(&mut scenario, ADDR_A);
        {
            let mut ag = ts::take_shared<Agreement>(&scenario);
            pacta::deposit_coin<TUSDC>(&mut ag, mint(100, ts::ctx(&mut scenario)), &clock, ts::ctx(&mut scenario));
            assert!(pacta::is_active(&ag));
            // ACTIVE is not a terminal state
            pacta::destroy(ag); // must abort EInvalidState
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    // ─── GROUP 12: Arbiter functions ─────────────────────────────────────────

    #[test]
    fun test_arbiter_settle_forces_cross_delivery() {
        let mut scenario = ts::begin(ADDR_A);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));

        let ag = make_arbiter_agreement(&clock, ts::ctx(&mut scenario));
        transfer::public_share_object(ag);

        // A deposits to move from CREATED → ACTIVE
        ts::next_tx(&mut scenario, ADDR_A);
        {
            let mut ag = ts::take_shared<Agreement>(&scenario);
            pacta::deposit_coin<TUSDC>(&mut ag, mint(100, ts::ctx(&mut scenario)), &clock, ts::ctx(&mut scenario));
            assert!(pacta::is_active(&ag));
            ts::return_shared(ag);
        };

        // Arbiter forces settlement
        ts::next_tx(&mut scenario, ADDR_ARB);
        {
            let mut ag = ts::take_shared<Agreement>(&scenario);
            pacta::arbiter_settle(&mut ag, &clock, ts::ctx(&mut scenario));
            assert!(pacta::is_settled(&ag));
            assert!(pacta::get_a_recipient(&ag) == ADDR_B); // cross-delivery
            assert!(pacta::get_b_recipient(&ag) == ADDR_A);
            ts::return_shared(ag);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    #[test]
    fun test_arbiter_cancel_forces_self_refund() {
        let mut scenario = ts::begin(ADDR_A);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));

        let ag = make_arbiter_agreement(&clock, ts::ctx(&mut scenario));
        transfer::public_share_object(ag);

        ts::next_tx(&mut scenario, ADDR_A);
        {
            let mut ag = ts::take_shared<Agreement>(&scenario);
            pacta::deposit_coin<TUSDC>(&mut ag, mint(100, ts::ctx(&mut scenario)), &clock, ts::ctx(&mut scenario));
            ts::return_shared(ag);
        };

        ts::next_tx(&mut scenario, ADDR_ARB);
        {
            let mut ag = ts::take_shared<Agreement>(&scenario);
            pacta::arbiter_cancel(&mut ag, ts::ctx(&mut scenario));
            assert!(pacta::is_cancelled(&ag));
            assert!(pacta::get_a_recipient(&ag) == ADDR_A); // self-refund
            assert!(pacta::get_b_recipient(&ag) == ADDR_B);
            ts::return_shared(ag);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = 2)]  // ENotArbiter
    fun test_non_arbiter_cannot_force_settle() {
        let mut scenario = ts::begin(ADDR_A);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));

        let ag = make_arbiter_agreement(&clock, ts::ctx(&mut scenario));
        transfer::public_share_object(ag);

        ts::next_tx(&mut scenario, ADDR_A);
        {
            let mut ag = ts::take_shared<Agreement>(&scenario);
            pacta::deposit_coin<TUSDC>(&mut ag, mint(100, ts::ctx(&mut scenario)), &clock, ts::ctx(&mut scenario));
            ts::return_shared(ag);
        };

        // ADDR_RANDO is not the arbiter
        ts::next_tx(&mut scenario, ADDR_RANDO);
        {
            let mut ag = ts::take_shared<Agreement>(&scenario);
            pacta::arbiter_settle(&mut ag, &clock, ts::ctx(&mut scenario)); // ENotArbiter
            ts::return_shared(ag);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    #[test]
    fun test_arbiter_cancel_on_disputed_agreement() {
        let mut scenario = ts::begin(ADDR_A);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));

        let ag = make_three_cond_agreement(&clock, ts::ctx(&mut scenario));
        // Reuse make_three_cond but override arbiter by creating directly
        test_utils::destroy(ag);

        let ag2 = pacta::create_agreement(
            ADDR_A, ADDR_B, ADDR_ARB,
            pacta::cond_a_deposited() | pacta::cond_b_deposited() | pacta::cond_a_approved(),
            b"", 0, 0, b"",
            &clock, ts::ctx(&mut scenario),
        );
        transfer::public_share_object(ag2);

        ts::next_tx(&mut scenario, ADDR_A);
        {
            let mut ag = ts::take_shared<Agreement>(&scenario);
            pacta::deposit_coin<TUSDC>(&mut ag, mint(100, ts::ctx(&mut scenario)), &clock, ts::ctx(&mut scenario));
            ts::return_shared(ag);
        };

        ts::next_tx(&mut scenario, ADDR_B);
        {
            let mut ag = ts::take_shared<Agreement>(&scenario);
            pacta::deposit_coin<TUSDC>(&mut ag, mint(200, ts::ctx(&mut scenario)), &clock, ts::ctx(&mut scenario));
            ts::return_shared(ag);
        };

        // A raises dispute
        ts::next_tx(&mut scenario, ADDR_A);
        {
            let mut ag = ts::take_shared<Agreement>(&scenario);
            pacta::raise_dispute(&mut ag, b"dispute", ts::ctx(&mut scenario));
            assert!(pacta::is_disputed(&ag));
            ts::return_shared(ag);
        };

        // Arbiter cancels a disputed agreement
        ts::next_tx(&mut scenario, ADDR_ARB);
        {
            let mut ag = ts::take_shared<Agreement>(&scenario);
            pacta::arbiter_cancel(&mut ag, ts::ctx(&mut scenario));
            assert!(pacta::is_cancelled(&ag));
            ts::return_shared(ag);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    // ─── GROUP 13: Dispute lifecycle ─────────────────────────────────────────
    //
    // There are two distinct resolution paths:
    //
    //   PATH A — winner-takes-all: raise_dispute → resolve_dispute(0|1)
    //            State moves directly to STATE_SETTLED. Parties claim via claim_coin.
    //
    //   PATH B — split-coin: raise_dispute → resolve_dispute_split_coin (transfers
    //            immediately, decrements active_slots, state stays DISPUTED) →
    //            once active_slots == 0 call conclude_dispute → DISPUTE_RESOLVED.

    #[test]
    fun test_dispute_winner_takes_all() {
        let mut scenario = ts::begin(ADDR_A);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));

        // Three-condition to prevent auto-settle after both deposit
        let ag = pacta::create_agreement(
            ADDR_A, ADDR_B, ADDR_ARB,
            pacta::cond_a_deposited() | pacta::cond_b_deposited() | pacta::cond_a_approved(),
            b"", 0, 0, b"",
            &clock, ts::ctx(&mut scenario),
        );
        transfer::public_share_object(ag);

        ts::next_tx(&mut scenario, ADDR_A);
        {
            let mut ag = ts::take_shared<Agreement>(&scenario);
            pacta::deposit_coin<TUSDC>(&mut ag, mint(100, ts::ctx(&mut scenario)), &clock, ts::ctx(&mut scenario));
            ts::return_shared(ag);
        };

        ts::next_tx(&mut scenario, ADDR_B);
        {
            let mut ag = ts::take_shared<Agreement>(&scenario);
            pacta::deposit_coin<TUSDC>(&mut ag, mint(200, ts::ctx(&mut scenario)), &clock, ts::ctx(&mut scenario));
            ts::return_shared(ag);
        };

        // A raises dispute
        ts::next_tx(&mut scenario, ADDR_A);
        {
            let mut ag = ts::take_shared<Agreement>(&scenario);
            pacta::raise_dispute(&mut ag, b"bad faith", ts::ctx(&mut scenario));
            assert!(pacta::is_disputed(&ag));
            ts::return_shared(ag);
        };

        // Arbiter resolves winner-takes-all: resolution=1 → B wins everything.
        // resolve_dispute transitions state directly to STATE_SETTLED.
        ts::next_tx(&mut scenario, ADDR_ARB);
        {
            let mut ag = ts::take_shared<Agreement>(&scenario);
            pacta::resolve_dispute(&mut ag, 1, ts::ctx(&mut scenario));
            assert!(pacta::is_settled(&ag)); // STATE_SETTLED, not DISPUTED
            // Both recipients point to party_b (winner takes all)
            assert!(pacta::get_a_recipient(&ag) == ADDR_B);
            assert!(pacta::get_b_recipient(&ag) == ADDR_B);
            ts::return_shared(ag);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    #[test]
    fun test_dispute_split_coin_and_conclude() {
        let mut scenario = ts::begin(ADDR_A);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));

        let ag = pacta::create_agreement(
            ADDR_A, ADDR_B, ADDR_ARB,
            pacta::cond_a_deposited() | pacta::cond_b_deposited() | pacta::cond_a_approved(),
            b"", 0, 0, b"",
            &clock, ts::ctx(&mut scenario),
        );
        transfer::public_share_object(ag);

        ts::next_tx(&mut scenario, ADDR_A);
        {
            let mut ag = ts::take_shared<Agreement>(&scenario);
            pacta::deposit_coin<TUSDC>(&mut ag, mint(100, ts::ctx(&mut scenario)), &clock, ts::ctx(&mut scenario));
            ts::return_shared(ag);
        };

        ts::next_tx(&mut scenario, ADDR_B);
        {
            let mut ag = ts::take_shared<Agreement>(&scenario);
            pacta::deposit_coin<TUSDC>(&mut ag, mint(200, ts::ctx(&mut scenario)), &clock, ts::ctx(&mut scenario));
            assert!(pacta::get_active_slots(&ag) == 2);
            ts::return_shared(ag);
        };

        ts::next_tx(&mut scenario, ADDR_A);
        {
            let mut ag = ts::take_shared<Agreement>(&scenario);
            pacta::raise_dispute(&mut ag, b"split needed", ts::ctx(&mut scenario));
            assert!(pacta::is_disputed(&ag));
            ts::return_shared(ag);
        };

        // Arbiter splits 50/50: transfers directly and decrements active_slots.
        // State remains DISPUTED after this call.
        ts::next_tx(&mut scenario, ADDR_ARB);
        {
            let mut ag = ts::take_shared<Agreement>(&scenario);
            pacta::resolve_dispute_split_coin<TUSDC>(&mut ag, 5000, ts::ctx(&mut scenario));
            assert!(pacta::is_disputed(&ag));       // state unchanged
            assert!(pacta::get_active_slots(&ag) == 0); // both slots drained
            ts::return_shared(ag);
        };

        // Now active_slots == 0 → conclude_dispute can proceed → DISPUTE_RESOLVED
        ts::next_tx(&mut scenario, ADDR_ARB);
        {
            let mut ag = ts::take_shared<Agreement>(&scenario);
            pacta::conclude_dispute(&mut ag, &clock, ts::ctx(&mut scenario));
            assert!(pacta::is_dispute_resolved(&ag));
            assert!(pacta::is_finalized(&ag));
            ts::return_shared(ag);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = 12)]  // ENoArbiter
    fun test_dispute_requires_arbiter() {
        let mut scenario = ts::begin(ADDR_A);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));

        // No arbiter set
        let ag = make_swap_agreement(&clock, ts::ctx(&mut scenario));
        transfer::public_share_object(ag);

        ts::next_tx(&mut scenario, ADDR_A);
        {
            let mut ag = ts::take_shared<Agreement>(&scenario);
            pacta::deposit_coin<TUSDC>(&mut ag, mint(100, ts::ctx(&mut scenario)), &clock, ts::ctx(&mut scenario));
            ts::return_shared(ag);
        };

        ts::next_tx(&mut scenario, ADDR_A);
        {
            let mut ag = ts::take_shared<Agreement>(&scenario);
            pacta::raise_dispute(&mut ag, b"oops", ts::ctx(&mut scenario)); // ENoArbiter
            ts::return_shared(ag);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    // ─── GROUP 14: record_outcome and registry ────────────────────────────────

    #[test]
    fun test_record_outcome_increments_total_settled() {
        let mut scenario = ts::begin(DEPLOYER);
        // init creates PactaRegistry (shared) and AdminCap (transferred to deployer)
        { pacta::init_for_testing(ts::ctx(&mut scenario)); };

        let clock = clock::create_for_testing(ts::ctx(&mut scenario));

        ts::next_tx(&mut scenario, ADDR_A);
        {
            let ag = make_swap_agreement(&clock, ts::ctx(&mut scenario));
            transfer::public_share_object(ag);
        };

        ts::next_tx(&mut scenario, ADDR_A);
        {
            let mut ag = ts::take_shared<Agreement>(&scenario);
            pacta::deposit_coin<TUSDC>(&mut ag, mint(100, ts::ctx(&mut scenario)), &clock, ts::ctx(&mut scenario));
            ts::return_shared(ag);
        };

        ts::next_tx(&mut scenario, ADDR_B);
        {
            let mut ag = ts::take_shared<Agreement>(&scenario);
            pacta::deposit_coin<TUSDC>(&mut ag, mint(200, ts::ctx(&mut scenario)), &clock, ts::ctx(&mut scenario));
            ts::return_shared(ag);
        };

        ts::next_tx(&mut scenario, ADDR_EXEC);
        {
            let mut ag = ts::take_shared<Agreement>(&scenario);
            let mut registry = ts::take_shared<PactaRegistry>(&scenario);
            assert!(pacta::total_settled(&registry) == 0);
            pacta::record_outcome(&mut ag, &mut registry);
            assert!(pacta::total_settled(&registry) == 1);
            assert!(pacta::registry_recorded(&ag));
            ts::return_shared(ag);
            ts::return_shared(registry);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    #[test]
    fun test_record_outcome_increments_total_cancelled() {
        let mut scenario = ts::begin(DEPLOYER);
        { pacta::init_for_testing(ts::ctx(&mut scenario)); };

        let clock = clock::create_for_testing(ts::ctx(&mut scenario));

        ts::next_tx(&mut scenario, ADDR_A);
        {
            let mut ag = make_swap_agreement(&clock, ts::ctx(&mut scenario));
            pacta::cancel(&mut ag, ts::ctx(&mut scenario));
            transfer::public_share_object(ag);
        };

        ts::next_tx(&mut scenario, ADDR_EXEC);
        {
            let mut ag = ts::take_shared<Agreement>(&scenario);
            let mut registry = ts::take_shared<PactaRegistry>(&scenario);
            assert!(pacta::total_cancelled(&registry) == 0);
            pacta::record_outcome(&mut ag, &mut registry);
            assert!(pacta::total_cancelled(&registry) == 1);
            assert!(pacta::total_settled(&registry) == 0);
            ts::return_shared(ag);
            ts::return_shared(registry);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = 20)]  // EAlreadyRecorded
    fun test_record_outcome_twice_fails() {
        let mut scenario = ts::begin(DEPLOYER);
        { pacta::init_for_testing(ts::ctx(&mut scenario)); };

        let clock = clock::create_for_testing(ts::ctx(&mut scenario));

        ts::next_tx(&mut scenario, ADDR_A);
        {
            let ag = make_swap_agreement(&clock, ts::ctx(&mut scenario));
            transfer::public_share_object(ag);
        };

        ts::next_tx(&mut scenario, ADDR_A);
        {
            let mut ag = ts::take_shared<Agreement>(&scenario);
            pacta::deposit_coin<TUSDC>(&mut ag, mint(100, ts::ctx(&mut scenario)), &clock, ts::ctx(&mut scenario));
            ts::return_shared(ag);
        };

        ts::next_tx(&mut scenario, ADDR_B);
        {
            let mut ag = ts::take_shared<Agreement>(&scenario);
            pacta::deposit_coin<TUSDC>(&mut ag, mint(100, ts::ctx(&mut scenario)), &clock, ts::ctx(&mut scenario));
            ts::return_shared(ag);
        };

        // First recording succeeds
        ts::next_tx(&mut scenario, ADDR_EXEC);
        {
            let mut ag = ts::take_shared<Agreement>(&scenario);
            let mut registry = ts::take_shared<PactaRegistry>(&scenario);
            pacta::record_outcome(&mut ag, &mut registry);
            ts::return_shared(ag);
            ts::return_shared(registry);
        };

        // Second recording must abort with EAlreadyRecorded
        ts::next_tx(&mut scenario, ADDR_EXEC);
        {
            let mut ag = ts::take_shared<Agreement>(&scenario);
            let mut registry = ts::take_shared<PactaRegistry>(&scenario);
            pacta::record_outcome(&mut ag, &mut registry);
            ts::return_shared(ag);
            ts::return_shared(registry);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    // ─── GROUP 15: set_party_b open-listing ───────────────────────────────────

    #[test]
    fun test_set_party_b_updates_open_agreement() {
        let mut scenario = ts::begin(ADDR_A);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));

        // Open agreement: party_b = @0x0
        let ag = pacta::create_agreement(
            ADDR_A, @0x0, @0x0,
            pacta::cond_a_deposited() | pacta::cond_b_deposited(),
            b"", 0, 0, b"",
            &clock, ts::ctx(&mut scenario),
        );
        transfer::public_share_object(ag);

        ts::next_tx(&mut scenario, ADDR_A);
        {
            let mut ag = ts::take_shared<Agreement>(&scenario);
            assert!(pacta::get_party_b(&ag) == @0x0);
            pacta::set_party_b(&mut ag, ADDR_B, ts::ctx(&mut scenario));
            assert!(pacta::get_party_b(&ag) == ADDR_B);
            ts::return_shared(ag);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = 19)]  // EPartyBAlreadyDeposited
    fun test_set_party_b_blocked_after_b_deposits() {
        let mut scenario = ts::begin(ADDR_A);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));

        // Three-condition so deposits don't immediately auto-settle
        let ag = make_three_cond_agreement(&clock, ts::ctx(&mut scenario));
        transfer::public_share_object(ag);

        // B deposits
        ts::next_tx(&mut scenario, ADDR_B);
        {
            let mut ag = ts::take_shared<Agreement>(&scenario);
            pacta::deposit_coin<TUSDC>(&mut ag, mint(100, ts::ctx(&mut scenario)), &clock, ts::ctx(&mut scenario));
            ts::return_shared(ag);
        };

        // A tries to change party_b after B has deposited → EPartyBAlreadyDeposited
        ts::next_tx(&mut scenario, ADDR_A);
        {
            let mut ag = ts::take_shared<Agreement>(&scenario);
            pacta::set_party_b(&mut ag, ADDR_RANDO, ts::ctx(&mut scenario));
            ts::return_shared(ag);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    // ─── GROUP 16: Non-party deposit rejected ────────────────────────────────

    #[test]
    #[expected_failure(abort_code = 0)]  // ENotParty
    fun test_non_party_cannot_deposit() {
        let mut scenario = ts::begin(ADDR_A);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));

        let ag = make_swap_agreement(&clock, ts::ctx(&mut scenario));
        transfer::public_share_object(ag);

        // ADDR_RANDO is not party_a or party_b
        ts::next_tx(&mut scenario, ADDR_RANDO);
        {
            let mut ag = ts::take_shared<Agreement>(&scenario);
            pacta::deposit_coin<TUSDC>(&mut ag, mint(100, ts::ctx(&mut scenario)), &clock, ts::ctx(&mut scenario)); // ENotParty
            ts::return_shared(ag);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    // ─── GROUP 17: is_ready_to_settle view ───────────────────────────────────

    #[test]
    fun test_is_ready_to_settle_reflects_conditions() {
        let mut scenario = ts::begin(ADDR_A);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));

        let ag = make_swap_agreement(&clock, ts::ctx(&mut scenario));
        transfer::public_share_object(ag);

        // CREATED state: not ready
        ts::next_tx(&mut scenario, ADDR_A);
        {
            let ag = ts::take_shared<Agreement>(&scenario);
            assert!(!pacta::is_ready_to_settle(&ag, &clock));
            ts::return_shared(ag);
        };

        // Only A deposited: not ready
        ts::next_tx(&mut scenario, ADDR_A);
        {
            let mut ag = ts::take_shared<Agreement>(&scenario);
            pacta::deposit_coin<TUSDC>(&mut ag, mint(100, ts::ctx(&mut scenario)), &clock, ts::ctx(&mut scenario));
            assert!(!pacta::is_ready_to_settle(&ag, &clock));
            ts::return_shared(ag);
        };

        // Both deposited: auto-settle already fired inside deposit_coin; state is SETTLED
        ts::next_tx(&mut scenario, ADDR_B);
        {
            let mut ag = ts::take_shared<Agreement>(&scenario);
            pacta::deposit_coin<TUSDC>(&mut ag, mint(200, ts::ctx(&mut scenario)), &clock, ts::ctx(&mut scenario));
            // Already settled — is_ready_to_settle returns false for non-ACTIVE state
            assert!(!pacta::is_ready_to_settle(&ag, &clock));
            assert!(pacta::is_settled(&ag));
            ts::return_shared(ag);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    // ─── GROUP 18: Protocol version constant ─────────────────────────────────

    #[test]
    fun test_protocol_version_is_four() {
        assert!(pacta::protocol_version() == 4);
    }
}
