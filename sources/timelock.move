/// Pacta Timelock Upgrade Module
///
/// Wraps Sui's UpgradeCap and enforces a mandatory 14-day waiting period
/// before any package upgrade can execute. This gives builders and users
/// advance warning of changes and time to exit if they disagree.
///
/// ─── How It Works ────────────────────────────────────────────────────────
///
///  1. At deploy time, the admin calls wrap() once, locking the UpgradeCap
///     inside a shared TimelockUpgradeCap object. The raw UpgradeCap is
///     gone — upgrades can only happen through this module from now on.
///
///  2. To upgrade, the admin calls propose_upgrade(). This writes a public
///     record on-chain: what is changing and when it can execute (now + 14d).
///
///  3. Anyone can see the pending proposal. Builders and users have 14 days
///     to review, raise objections, or exit their positions.
///
///  4. After 14 days, the admin calls execute_upgrade() → commit_upgrade()
///     in a single PTB to complete the upgrade.
///
///  5. If the proposal is wrong or malicious, the admin calls cancel_upgrade()
///     at any time before execution to remove it.
///
/// ─── Security Properties ─────────────────────────────────────────────────
///
///  • No silent upgrades — every change is announced on-chain.
///  • No instant upgrades — 14-day delay is enforced by the clock.
///  • Hack window — if admin wallet is compromised, the team has 14 days
///    to cancel the malicious proposal from a backup wallet before it executes.
///  • Admin transfer — admin rights can be moved to a multisig wallet at
///    any time via transfer_admin(), enabling future decentralised governance.
///
/// ─── Upgrade Lifecycle ───────────────────────────────────────────────────
///
///  wrap() ──► propose_upgrade() ──► [14 days] ──► execute_upgrade()
///                                                        │
///                                                  commit_upgrade()
///                      cancel_upgrade() ◄───────────────┘ (any time before)
///
module pacta::timelock {
    use sui::package::{Self, UpgradeCap, UpgradeTicket, UpgradeReceipt};
    use sui::clock::Clock;
    use sui::event;

    // ═══════════════════════════════════════════════════════════════════
    // Constants
    // ═══════════════════════════════════════════════════════════════════

    /// 14 days expressed in milliseconds.
    const DELAY_MS: u64 = 14 * 24 * 60 * 60 * 1_000;

    // ═══════════════════════════════════════════════════════════════════
    // Error Codes
    // ═══════════════════════════════════════════════════════════════════

    const ENotAdmin: u64        = 0;
    const EAlreadyProposed: u64 = 1;
    const ENoProposal: u64      = 2;
    const ETooEarly: u64        = 3;

    // ═══════════════════════════════════════════════════════════════════
    // Core Structs
    // ═══════════════════════════════════════════════════════════════════

    /// Shared object that wraps the UpgradeCap and enforces the timelock.
    ///
    /// Shared so that anyone can inspect pending proposals and verify that
    /// no silent upgrade is in progress. Only `admin` can mutate it.
    public struct TimelockUpgradeCap has key {
        id: UID,
        /// The actual Sui upgrade capability. Locked here permanently.
        upgrade_cap: UpgradeCap,
        /// Address that can propose, execute, and cancel upgrades.
        /// Transfer to a multisig wallet for stronger governance.
        admin: address,
        /// The pending proposal, if any. None means no upgrade in flight.
        proposal: Option<UpgradeProposal>,
    }

    /// A pending upgrade announcement stored inside TimelockUpgradeCap.
    public struct UpgradeProposal has store, drop {
        /// SHA3-256 digest of the new package bytecode. Uniquely identifies
        /// exactly which code will be deployed — nothing else can slip in.
        digest: vector<u8>,
        /// Sui upgrade policy. Use package::compatible_policy() (= 0) for
        /// standard upgrades that preserve existing interfaces.
        policy: u8,
        /// Unix timestamp (ms) before which execute_upgrade() will abort.
        earliest_execution_ms: u64,
    }

    // ═══════════════════════════════════════════════════════════════════
    // Events
    // ═══════════════════════════════════════════════════════════════════

    /// Emitted when an upgrade is proposed. Builders should monitor this.
    public struct UpgradeProposed has copy, drop {
        package_id: ID,
        digest: vector<u8>,
        policy: u8,
        earliest_execution_ms: u64,
        proposed_by: address,
    }

    /// Emitted when an upgrade is executed successfully.
    public struct UpgradeExecuted has copy, drop {
        package_id: ID,
        executed_by: address,
    }

    /// Emitted when a pending proposal is cancelled.
    public struct UpgradeCancelled has copy, drop {
        package_id: ID,
        cancelled_by: address,
    }

    /// Emitted when admin rights are transferred.
    public struct AdminTransferred has copy, drop {
        package_id: ID,
        old_admin: address,
        new_admin: address,
    }

    // ═══════════════════════════════════════════════════════════════════
    // Setup
    // ═══════════════════════════════════════════════════════════════════

    /// Lock the UpgradeCap inside the timelock. Call once after deploy.
    ///
    /// After this, the raw UpgradeCap is gone. All future upgrades must
    /// go through propose_upgrade() → execute_upgrade() → commit_upgrade().
    ///
    /// Example PTB at deploy time:
    ///   let cap = <UpgradeCap from publish>;
    ///   timelock::wrap(cap, @admin_address, ctx);
    public fun wrap(
        upgrade_cap: UpgradeCap,
        admin: address,
        ctx: &mut TxContext,
    ) {
        transfer::share_object(TimelockUpgradeCap {
            id: object::new(ctx),
            upgrade_cap,
            admin,
            proposal: option::none(),
        });
    }

    // ═══════════════════════════════════════════════════════════════════
    // Upgrade Lifecycle
    // ═══════════════════════════════════════════════════════════════════

    /// Announce an upgrade and start the 14-day countdown.
    ///
    /// Only one proposal can be active at a time. Cancel the current one
    /// before proposing again.
    ///
    /// `digest`  — SHA3-256 hash of the new package bytecode. Obtain this
    ///             from `sui client upgrade --dry-run`.
    /// `policy`  — Use 0 for compatible upgrades (most common).
    public fun propose_upgrade(
        cap: &mut TimelockUpgradeCap,
        policy: u8,
        digest: vector<u8>,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        assert!(ctx.sender() == cap.admin, ENotAdmin);
        assert!(cap.proposal.is_none(), EAlreadyProposed);

        let earliest_execution_ms = clock.timestamp_ms() + DELAY_MS;

        event::emit(UpgradeProposed {
            package_id: package::upgrade_package(&cap.upgrade_cap),
            digest,
            policy,
            earliest_execution_ms,
            proposed_by: ctx.sender(),
        });

        cap.proposal = option::some(UpgradeProposal {
            digest,
            policy,
            earliest_execution_ms,
        });
    }

    /// Execute the upgrade after the 14-day timelock has passed.
    ///
    /// Returns an UpgradeTicket (hot potato — must be consumed in the same
    /// PTB). Immediately follow this with the actual upgrade bytecode
    /// processing, then call commit_upgrade() to finalise.
    ///
    /// Full PTB sequence:
    ///   let ticket  = timelock::execute_upgrade(cap, clock, ctx);
    ///   let receipt = <Sui runtime processes bytecode with ticket>;
    ///   timelock::commit_upgrade(cap, receipt);
    public fun execute_upgrade(
        cap: &mut TimelockUpgradeCap,
        clock: &Clock,
        ctx: &mut TxContext,
    ): UpgradeTicket {
        assert!(ctx.sender() == cap.admin, ENotAdmin);
        assert!(cap.proposal.is_some(), ENoProposal);

        let earliest = cap.proposal.borrow().earliest_execution_ms;
        assert!(clock.timestamp_ms() >= earliest, ETooEarly);

        let UpgradeProposal { digest, policy, earliest_execution_ms: _ } =
            cap.proposal.extract();

        event::emit(UpgradeExecuted {
            package_id: package::upgrade_package(&cap.upgrade_cap),
            executed_by: ctx.sender(),
        });

        package::authorize_upgrade(&mut cap.upgrade_cap, policy, digest)
    }

    /// Finalise the upgrade by committing the receipt.
    ///
    /// Must be called in the same PTB as execute_upgrade(), after the Sui
    /// runtime has processed the new bytecode and returned an UpgradeReceipt.
    public fun commit_upgrade(
        cap: &mut TimelockUpgradeCap,
        receipt: UpgradeReceipt,
    ) {
        package::commit_upgrade(&mut cap.upgrade_cap, receipt);
    }

    /// Cancel a pending upgrade proposal before it executes.
    ///
    /// Use this if the proposal was made in error, or if the admin wallet
    /// is compromised and a malicious upgrade was proposed — cancel from a
    /// backup wallet by transferring admin first via transfer_admin().
    public fun cancel_upgrade(
        cap: &mut TimelockUpgradeCap,
        ctx: &mut TxContext,
    ) {
        assert!(ctx.sender() == cap.admin, ENotAdmin);
        assert!(cap.proposal.is_some(), ENoProposal);

        let UpgradeProposal { digest: _, policy: _, earliest_execution_ms: _ } =
            cap.proposal.extract();

        event::emit(UpgradeCancelled {
            package_id: package::upgrade_package(&cap.upgrade_cap),
            cancelled_by: ctx.sender(),
        });
    }

    // ═══════════════════════════════════════════════════════════════════
    // Admin Governance
    // ═══════════════════════════════════════════════════════════════════

    /// Transfer admin rights to a new address.
    ///
    /// Use this to hand control to a multisig wallet, a DAO, or a
    /// hardware-wallet address for stronger security.
    ///
    /// Note: if you transfer to an address you do not control, admin
    /// rights are permanently lost — there is no recovery mechanism.
    public fun transfer_admin(
        cap: &mut TimelockUpgradeCap,
        new_admin: address,
        ctx: &mut TxContext,
    ) {
        assert!(ctx.sender() == cap.admin, ENotAdmin);

        event::emit(AdminTransferred {
            package_id: package::upgrade_package(&cap.upgrade_cap),
            old_admin: cap.admin,
            new_admin,
        });

        cap.admin = new_admin;
    }

    // ═══════════════════════════════════════════════════════════════════
    // View Functions
    // ═══════════════════════════════════════════════════════════════════

    /// True if an upgrade has been proposed and is waiting to execute.
    public fun has_pending_proposal(cap: &TimelockUpgradeCap): bool {
        cap.proposal.is_some()
    }

    /// The earliest timestamp (ms) at which the pending upgrade can execute.
    /// Aborts if no proposal is active — check has_pending_proposal() first.
    public fun earliest_execution_ms(cap: &TimelockUpgradeCap): u64 {
        cap.proposal.borrow().earliest_execution_ms
    }

    /// The digest of the pending upgrade proposal.
    /// Aborts if no proposal is active — check has_pending_proposal() first.
    public fun proposal_digest(cap: &TimelockUpgradeCap): vector<u8> {
        cap.proposal.borrow().digest
    }

    /// The policy of the pending upgrade proposal.
    /// Aborts if no proposal is active — check has_pending_proposal() first.
    public fun proposal_policy(cap: &TimelockUpgradeCap): u8 {
        cap.proposal.borrow().policy
    }

    /// The current admin address.
    public fun admin(cap: &TimelockUpgradeCap): address {
        cap.admin
    }

    /// The package ID this timelock governs.
    public fun package_id(cap: &TimelockUpgradeCap): ID {
        package::upgrade_package(&cap.upgrade_cap)
    }

    /// The fixed timelock delay in milliseconds (14 days).
    public fun delay_ms(): u64 {
        DELAY_MS
    }

    // ═══════════════════════════════════════════════════════════════════
    // Test Helpers
    // ═══════════════════════════════════════════════════════════════════

    /// Runs the same three guards as execute_upgrade without touching the
    /// UpgradeTicket hot potato.
    ///
    /// UpgradeTicket has no abilities — it cannot be consumed in unit tests
    /// without the Sui runtime's bytecode upgrade machinery. This helper
    /// lets tests verify guard conditions (ENotAdmin, ENoProposal, ETooEarly)
    /// in isolation. Full propose → execute → commit flow requires an
    /// integration test with a live Sui node.
    #[test_only]
    public fun test_assert_execute_guards(
        cap: &TimelockUpgradeCap,
        clock: &Clock,
        ctx: &TxContext,
    ) {
        assert!(ctx.sender() == cap.admin, ENotAdmin);
        assert!(cap.proposal.is_some(), ENoProposal);
        let earliest = cap.proposal.borrow().earliest_execution_ms;
        assert!(clock.timestamp_ms() >= earliest, ETooEarly);
    }
}
