/// Timelock Upgrade Module Tests
///
/// GROUP  1 — wrap() initialises state correctly
/// GROUP  2 — propose_upgrade() records proposal and emits event
/// GROUP  3 — execute_upgrade() aborts before delay expires (ETooEarly)
/// GROUP  4 — execute_upgrade() aborts with no proposal (ENoProposal)
/// GROUP  5 — cancel_upgrade() removes pending proposal
/// GROUP  6 — can propose again after cancel
/// GROUP  7 — non-admin cannot propose, execute, cancel, or transfer
/// GROUP  8 — double-propose blocked (EAlreadyProposed)
/// GROUP  9 — transfer_admin() hands control to new address
/// GROUP 10 — old admin blocked after transfer
/// GROUP 11 — view functions reflect live state correctly
///
/// NOTE — execute_upgrade() success path cannot be unit-tested:
///   execute_upgrade() returns an UpgradeTicket (hot potato). In the real Sui
///   runtime, this ticket is consumed by the bytecode upgrade machinery within
///   the same PTB. There is no test-only mechanism to consume it in Move unit
///   tests. The negative paths (ETooEarly, ENoProposal, ENotAdmin) are fully
///   tested here. The full propose → execute → commit flow requires an
///   integration test with a live Sui node (sui::test_cluster).
///
#[test_only]
module pacta::timelock_tests {
    use pacta::timelock::{Self, TimelockUpgradeCap};
    use sui::test_scenario::{Self as ts};
    use sui::clock::{Self};
    use sui::package;

    // ── Test addresses ───────────────────────────────────────────────────────

    const ADMIN:     address = @0xAA;
    const NON_ADMIN: address = @0xBB;
    const NEW_ADMIN: address = @0xCC;

    // ── 14 days in milliseconds ──────────────────────────────────────────────

    const DELAY_MS: u64 = 14 * 24 * 60 * 60 * 1_000;

    // ── Dummy digest (32 bytes) ──────────────────────────────────────────────

    fun dummy_digest(): vector<u8> {
        vector[
            1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,
            17,18,19,20,21,22,23,24,25,26,27,28,29,30,31,32
        ]
    }

    // ── Setup helper — wraps a test UpgradeCap and shares the TimelockUpgradeCap ──

    fun setup(scenario: &mut ts::Scenario) {
        ts::next_tx(scenario, ADMIN);
        {
            let cap = package::test_publish(
                object::id_from_address(@pacta),
                ts::ctx(scenario),
            );
            timelock::wrap(cap, ADMIN, ts::ctx(scenario));
        };
    }

    // ═══════════════════════════════════════════════════════════════════
    // GROUP 1 — wrap() initialises state correctly
    // ═══════════════════════════════════════════════════════════════════

    #[test]
    fun test_wrap_sets_admin_and_no_proposal() {
        let mut scenario = ts::begin(ADMIN);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));

        setup(&mut scenario);

        ts::next_tx(&mut scenario, ADMIN);
        {
            let tl = ts::take_shared<TimelockUpgradeCap>(&scenario);
            assert!(timelock::admin(&tl) == ADMIN);
            assert!(!timelock::has_pending_proposal(&tl));
            assert!(timelock::delay_ms() == DELAY_MS);
            ts::return_shared(tl);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    // ═══════════════════════════════════════════════════════════════════
    // GROUP 2 — propose_upgrade() records proposal
    // ═══════════════════════════════════════════════════════════════════

    #[test]
    fun test_propose_records_proposal_with_correct_deadline() {
        let mut scenario = ts::begin(ADMIN);
        let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));
        clock::set_for_testing(&mut clock, 1_000_000);

        setup(&mut scenario);

        ts::next_tx(&mut scenario, ADMIN);
        {
            let mut tl = ts::take_shared<TimelockUpgradeCap>(&scenario);
            timelock::propose_upgrade(
                &mut tl, 0, dummy_digest(), &clock, ts::ctx(&mut scenario),
            );
            assert!(timelock::has_pending_proposal(&tl));
            assert!(timelock::earliest_execution_ms(&tl) == 1_000_000 + DELAY_MS);
            assert!(timelock::proposal_digest(&tl) == dummy_digest());
            assert!(timelock::proposal_policy(&tl) == 0);
            ts::return_shared(tl);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    // ═══════════════════════════════════════════════════════════════════
    // GROUP 3 — execute_upgrade() guard: ETooEarly
    //
    // NOTE: execute_upgrade() returns an UpgradeTicket (hot potato with no
    // abilities). The Move compiler requires hot potatoes to be consumed on
    // ALL code paths — including abort paths — so we cannot call
    // execute_upgrade() in a unit test and let it return the ticket.
    //
    // Instead we use test_assert_execute_guards(), a #[test_only] helper
    // in timelock.move that runs the same three asserts without touching
    // the UpgradeTicket. This gives us full guard coverage in unit tests.
    // The full propose → execute → commit flow is tested via integration
    // tests with a live Sui node.
    // ═══════════════════════════════════════════════════════════════════

    #[test]
    #[expected_failure(abort_code = 3)] // ETooEarly
    fun test_execute_one_ms_before_deadline_aborts() {
        let mut scenario = ts::begin(ADMIN);
        let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));
        clock::set_for_testing(&mut clock, 0);

        setup(&mut scenario);

        ts::next_tx(&mut scenario, ADMIN);
        {
            let mut tl = ts::take_shared<TimelockUpgradeCap>(&scenario);
            timelock::propose_upgrade(
                &mut tl, 0, dummy_digest(), &clock, ts::ctx(&mut scenario),
            );
            ts::return_shared(tl);
        };

        // One millisecond before the deadline — guard must fire ETooEarly
        clock::set_for_testing(&mut clock, DELAY_MS - 1);

        ts::next_tx(&mut scenario, ADMIN);
        {
            let tl = ts::take_shared<TimelockUpgradeCap>(&scenario);
            timelock::test_assert_execute_guards(&tl, &clock, ts::ctx(&mut scenario));
            ts::return_shared(tl);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = 3)] // ETooEarly
    fun test_execute_at_zero_ms_aborts() {
        let mut scenario = ts::begin(ADMIN);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario)); // clock = 0

        setup(&mut scenario);

        ts::next_tx(&mut scenario, ADMIN);
        {
            let mut tl = ts::take_shared<TimelockUpgradeCap>(&scenario);
            timelock::propose_upgrade(
                &mut tl, 0, dummy_digest(), &clock, ts::ctx(&mut scenario),
            );
            ts::return_shared(tl);
        };

        // Clock still at 0 — deadline is DELAY_MS — way too early
        ts::next_tx(&mut scenario, ADMIN);
        {
            let tl = ts::take_shared<TimelockUpgradeCap>(&scenario);
            timelock::test_assert_execute_guards(&tl, &clock, ts::ctx(&mut scenario));
            ts::return_shared(tl);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    #[test]
    fun test_execute_at_exact_deadline_passes_guards() {
        let mut scenario = ts::begin(ADMIN);
        let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));
        clock::set_for_testing(&mut clock, 0);

        setup(&mut scenario);

        ts::next_tx(&mut scenario, ADMIN);
        {
            let mut tl = ts::take_shared<TimelockUpgradeCap>(&scenario);
            timelock::propose_upgrade(
                &mut tl, 0, dummy_digest(), &clock, ts::ctx(&mut scenario),
            );
            ts::return_shared(tl);
        };

        // Advance clock to exactly the deadline — guards must pass
        clock::set_for_testing(&mut clock, DELAY_MS);

        ts::next_tx(&mut scenario, ADMIN);
        {
            let tl = ts::take_shared<TimelockUpgradeCap>(&scenario);
            // No abort — all three guards pass
            timelock::test_assert_execute_guards(&tl, &clock, ts::ctx(&mut scenario));
            ts::return_shared(tl);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    // ═══════════════════════════════════════════════════════════════════
    // GROUP 4 — execute_upgrade() guard: ENoProposal
    // ═══════════════════════════════════════════════════════════════════

    #[test]
    #[expected_failure(abort_code = 2)] // ENoProposal
    fun test_execute_with_no_proposal_aborts() {
        let mut scenario = ts::begin(ADMIN);
        let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));
        clock::set_for_testing(&mut clock, DELAY_MS + 1);

        setup(&mut scenario);

        ts::next_tx(&mut scenario, ADMIN);
        {
            let tl = ts::take_shared<TimelockUpgradeCap>(&scenario);
            // No proposal — guard must fire ENoProposal
            timelock::test_assert_execute_guards(&tl, &clock, ts::ctx(&mut scenario));
            ts::return_shared(tl);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    // ═══════════════════════════════════════════════════════════════════
    // GROUP 5 — cancel_upgrade() removes pending proposal
    // ═══════════════════════════════════════════════════════════════════

    #[test]
    fun test_cancel_removes_proposal() {
        let mut scenario = ts::begin(ADMIN);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));

        setup(&mut scenario);

        ts::next_tx(&mut scenario, ADMIN);
        {
            let mut tl = ts::take_shared<TimelockUpgradeCap>(&scenario);
            timelock::propose_upgrade(
                &mut tl, 0, dummy_digest(), &clock, ts::ctx(&mut scenario),
            );
            assert!(timelock::has_pending_proposal(&tl));
            timelock::cancel_upgrade(&mut tl, ts::ctx(&mut scenario));
            assert!(!timelock::has_pending_proposal(&tl));
            ts::return_shared(tl);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = 2)] // ENoProposal
    fun test_cancel_with_no_proposal_aborts() {
        let mut scenario = ts::begin(ADMIN);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));

        setup(&mut scenario);

        ts::next_tx(&mut scenario, ADMIN);
        {
            let mut tl = ts::take_shared<TimelockUpgradeCap>(&scenario);
            timelock::cancel_upgrade(&mut tl, ts::ctx(&mut scenario));
            ts::return_shared(tl);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    // ═══════════════════════════════════════════════════════════════════
    // GROUP 6 — can propose again after cancel
    // ═══════════════════════════════════════════════════════════════════

    #[test]
    fun test_can_propose_again_after_cancel() {
        let mut scenario = ts::begin(ADMIN);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));

        setup(&mut scenario);

        ts::next_tx(&mut scenario, ADMIN);
        {
            let mut tl = ts::take_shared<TimelockUpgradeCap>(&scenario);
            timelock::propose_upgrade(
                &mut tl, 0, dummy_digest(), &clock, ts::ctx(&mut scenario),
            );
            timelock::cancel_upgrade(&mut tl, ts::ctx(&mut scenario));
            // Second propose after cancel must succeed
            timelock::propose_upgrade(
                &mut tl, 0, dummy_digest(), &clock, ts::ctx(&mut scenario),
            );
            assert!(timelock::has_pending_proposal(&tl));
            ts::return_shared(tl);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    // ═══════════════════════════════════════════════════════════════════
    // GROUP 7 — non-admin blocked from all mutations
    // ═══════════════════════════════════════════════════════════════════

    #[test]
    #[expected_failure(abort_code = 0)] // ENotAdmin
    fun test_non_admin_cannot_propose() {
        let mut scenario = ts::begin(ADMIN);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));

        setup(&mut scenario);

        ts::next_tx(&mut scenario, NON_ADMIN);
        {
            let mut tl = ts::take_shared<TimelockUpgradeCap>(&scenario);
            timelock::propose_upgrade(
                &mut tl, 0, dummy_digest(), &clock, ts::ctx(&mut scenario),
            );
            ts::return_shared(tl);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = 0)] // ENotAdmin
    fun test_non_admin_cannot_cancel() {
        let mut scenario = ts::begin(ADMIN);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));

        setup(&mut scenario);

        ts::next_tx(&mut scenario, ADMIN);
        {
            let mut tl = ts::take_shared<TimelockUpgradeCap>(&scenario);
            timelock::propose_upgrade(
                &mut tl, 0, dummy_digest(), &clock, ts::ctx(&mut scenario),
            );
            ts::return_shared(tl);
        };

        ts::next_tx(&mut scenario, NON_ADMIN);
        {
            let mut tl = ts::take_shared<TimelockUpgradeCap>(&scenario);
            timelock::cancel_upgrade(&mut tl, ts::ctx(&mut scenario));
            ts::return_shared(tl);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = 0)] // ENotAdmin
    fun test_non_admin_cannot_execute() {
        let mut scenario = ts::begin(ADMIN);
        let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));
        clock::set_for_testing(&mut clock, 0);

        setup(&mut scenario);

        ts::next_tx(&mut scenario, ADMIN);
        {
            let mut tl = ts::take_shared<TimelockUpgradeCap>(&scenario);
            timelock::propose_upgrade(
                &mut tl, 0, dummy_digest(), &clock, ts::ctx(&mut scenario),
            );
            ts::return_shared(tl);
        };

        clock::set_for_testing(&mut clock, DELAY_MS + 1);

        ts::next_tx(&mut scenario, NON_ADMIN);
        {
            let tl = ts::take_shared<TimelockUpgradeCap>(&scenario);
            // Guard fires ENotAdmin — same guard as in execute_upgrade
            timelock::test_assert_execute_guards(&tl, &clock, ts::ctx(&mut scenario));
            ts::return_shared(tl);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = 0)] // ENotAdmin
    fun test_non_admin_cannot_transfer_admin() {
        let mut scenario = ts::begin(ADMIN);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));

        setup(&mut scenario);

        ts::next_tx(&mut scenario, NON_ADMIN);
        {
            let mut tl = ts::take_shared<TimelockUpgradeCap>(&scenario);
            timelock::transfer_admin(&mut tl, NON_ADMIN, ts::ctx(&mut scenario));
            ts::return_shared(tl);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    // ═══════════════════════════════════════════════════════════════════
    // GROUP 8 — double-propose blocked
    // ═══════════════════════════════════════════════════════════════════

    #[test]
    #[expected_failure(abort_code = 1)] // EAlreadyProposed
    fun test_double_propose_aborts() {
        let mut scenario = ts::begin(ADMIN);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));

        setup(&mut scenario);

        ts::next_tx(&mut scenario, ADMIN);
        {
            let mut tl = ts::take_shared<TimelockUpgradeCap>(&scenario);
            timelock::propose_upgrade(
                &mut tl, 0, dummy_digest(), &clock, ts::ctx(&mut scenario),
            );
            // Second propose without cancelling — must abort EAlreadyProposed
            timelock::propose_upgrade(
                &mut tl, 0, dummy_digest(), &clock, ts::ctx(&mut scenario),
            );
            ts::return_shared(tl);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    // ═══════════════════════════════════════════════════════════════════
    // GROUP 9 — transfer_admin() hands control to new address
    // ═══════════════════════════════════════════════════════════════════

    #[test]
    fun test_transfer_admin_new_admin_can_propose() {
        let mut scenario = ts::begin(ADMIN);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));

        setup(&mut scenario);

        ts::next_tx(&mut scenario, ADMIN);
        {
            let mut tl = ts::take_shared<TimelockUpgradeCap>(&scenario);
            timelock::transfer_admin(&mut tl, NEW_ADMIN, ts::ctx(&mut scenario));
            assert!(timelock::admin(&tl) == NEW_ADMIN);
            ts::return_shared(tl);
        };

        ts::next_tx(&mut scenario, NEW_ADMIN);
        {
            let mut tl = ts::take_shared<TimelockUpgradeCap>(&scenario);
            timelock::propose_upgrade(
                &mut tl, 0, dummy_digest(), &clock, ts::ctx(&mut scenario),
            );
            assert!(timelock::has_pending_proposal(&tl));
            ts::return_shared(tl);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    // ═══════════════════════════════════════════════════════════════════
    // GROUP 10 — old admin blocked after transfer
    // ═══════════════════════════════════════════════════════════════════

    #[test]
    #[expected_failure(abort_code = 0)] // ENotAdmin
    fun test_old_admin_blocked_after_transfer() {
        let mut scenario = ts::begin(ADMIN);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));

        setup(&mut scenario);

        ts::next_tx(&mut scenario, ADMIN);
        {
            let mut tl = ts::take_shared<TimelockUpgradeCap>(&scenario);
            timelock::transfer_admin(&mut tl, NEW_ADMIN, ts::ctx(&mut scenario));
            ts::return_shared(tl);
        };

        // Old ADMIN tries to propose — must abort since NEW_ADMIN is now admin
        ts::next_tx(&mut scenario, ADMIN);
        {
            let mut tl = ts::take_shared<TimelockUpgradeCap>(&scenario);
            timelock::propose_upgrade(
                &mut tl, 0, dummy_digest(), &clock, ts::ctx(&mut scenario),
            );
            ts::return_shared(tl);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    // ═══════════════════════════════════════════════════════════════════
    // GROUP 11 — view functions reflect live state
    // ═══════════════════════════════════════════════════════════════════

    #[test]
    fun test_view_functions_reflect_state_transitions() {
        let mut scenario = ts::begin(ADMIN);
        let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));
        clock::set_for_testing(&mut clock, 5_000_000);

        setup(&mut scenario);

        ts::next_tx(&mut scenario, ADMIN);
        {
            let mut tl = ts::take_shared<TimelockUpgradeCap>(&scenario);

            // Before proposal
            assert!(!timelock::has_pending_proposal(&tl));
            assert!(timelock::admin(&tl) == ADMIN);
            assert!(timelock::delay_ms() == DELAY_MS);

            timelock::propose_upgrade(
                &mut tl, 0, dummy_digest(), &clock, ts::ctx(&mut scenario),
            );

            // After proposal
            assert!(timelock::has_pending_proposal(&tl));
            assert!(timelock::earliest_execution_ms(&tl) == 5_000_000 + DELAY_MS);
            assert!(timelock::proposal_digest(&tl) == dummy_digest());
            assert!(timelock::proposal_policy(&tl) == 0);

            timelock::cancel_upgrade(&mut tl, ts::ctx(&mut scenario));

            // After cancel
            assert!(!timelock::has_pending_proposal(&tl));

            ts::return_shared(tl);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }
}
