import { Transaction } from "@mysten/sui/transactions"
import {
  NetworkConfig,
  CreateAgreementParams,
  DepositCoinParams,
  ApproveParams,
  SettleParams,
  CancelParams,
  MutualCancelParams,
  RaiseDisputeParams,
  ResolveDisputeParams,
  ClaimCoinParams,
  SetPartyBParams,
} from "./types"

// SUI_CLOCK_OBJECT_ID is a well-known shared object on all Sui networks
const SUI_CLOCK_OBJECT_ID = "0x6"

// ─── Agreement Lifecycle ──────────────────────────────────────────────────────

/**
 * Build a PTB that creates a new agreement and shares it on-chain.
 * Caller must be party_a (or a delegated creator).
 */
export function buildCreateAgreement(
  config: NetworkConfig,
  params: CreateAgreementParams,
): Transaction {
  const tx = new Transaction()

  tx.moveCall({
    target:    `${config.packageId}::pacta::create_and_share`,
    arguments: [
      tx.pure.address(params.partyA),
      tx.pure.address(params.partyB),
      tx.pure.address(params.arbiter),
      tx.pure.u8(params.releaseConditions),
      tx.pure.vector("u8", hexToBytes(params.termsHash)),
      tx.pure.u64(params.expiryMs),
      tx.pure.u64(params.unlockTimeMs),
      tx.pure.vector("u8", hexToBytes(params.metadata ?? "0x")),
      tx.object(SUI_CLOCK_OBJECT_ID),
    ],
  })

  return tx
}

/**
 * Build a PTB that updates party B's address before they have deposited.
 * Only the agreement creator can call this.
 */
export function buildSetPartyB(
  config: NetworkConfig,
  params: SetPartyBParams,
): Transaction {
  const tx = new Transaction()

  tx.moveCall({
    target:    `${config.packageId}::pacta::set_party_b`,
    arguments: [
      tx.object(params.agreementId),
      tx.pure.address(params.newPartyB),
    ],
  })

  return tx
}

/**
 * Build a PTB that deposits a coin into the agreement.
 * Works for both party A and party B — the contract resolves the party from
 * the sender address.
 */
export function buildDepositCoin(
  config: NetworkConfig,
  params: DepositCoinParams,
): Transaction {
  const tx = new Transaction()

  tx.moveCall({
    target:         `${config.packageId}::pacta::deposit_coin`,
    typeArguments:  [params.coinType],
    arguments:      [
      tx.object(params.agreementId),
      tx.object(params.coinObjectId),
      tx.object(SUI_CLOCK_OBJECT_ID),
    ],
  })

  return tx
}

/**
 * Build a PTB that records the caller's approval to release funds.
 * Both parties must approve (if conditions require it) before settlement.
 */
export function buildApprove(
  config: NetworkConfig,
  params: ApproveParams,
): Transaction {
  const tx = new Transaction()

  tx.moveCall({
    target:    `${config.packageId}::pacta::approve`,
    arguments: [
      tx.object(params.agreementId),
      tx.object(SUI_CLOCK_OBJECT_ID),
    ],
  })

  return tx
}

/**
 * Build a PTB that settles the agreement and releases funds to both parties.
 *
 * Uses settle_with_receipt + consume_settlement_receipt in a single PTB.
 * Any address can call this once all conditions are met (permissionless executor).
 */
export function buildSettle(
  config: NetworkConfig,
  params: SettleParams,
): Transaction {
  const tx = new Transaction()

  const [receipt] = tx.moveCall({
    target:    `${config.packageId}::pacta::settle_with_receipt`,
    arguments: [
      tx.object(params.agreementId),
      tx.object(SUI_CLOCK_OBJECT_ID),
    ],
  })

  tx.moveCall({
    target:    `${config.packageId}::pacta::consume_settlement_receipt`,
    arguments: [receipt],
  })

  return tx
}

/**
 * Build a PTB that cancels an agreement.
 * In CREATED state: only the creator can cancel.
 * In ACTIVE state: only party_a or party_b can cancel (if no funds deposited).
 */
export function buildCancel(
  config: NetworkConfig,
  params: CancelParams,
): Transaction {
  const tx = new Transaction()

  tx.moveCall({
    target:    `${config.packageId}::pacta::cancel`,
    arguments: [tx.object(params.agreementId)],
  })

  return tx
}

/**
 * Build a PTB that signals mutual cancel consent.
 * Both parties must call this. When both have consented the agreement cancels.
 */
export function buildMutualCancel(
  config: NetworkConfig,
  params: MutualCancelParams,
): Transaction {
  const tx = new Transaction()

  tx.moveCall({
    target:    `${config.packageId}::pacta::mutual_cancel`,
    arguments: [tx.object(params.agreementId)],
  })

  return tx
}

/**
 * Build a PTB that cancels an expired agreement.
 * Anyone can call this once the expiry timestamp has passed.
 */
export function buildCancelExpired(
  config: NetworkConfig,
  agreementId: string,
): Transaction {
  const tx = new Transaction()

  tx.moveCall({
    target:    `${config.packageId}::pacta::cancel_expired`,
    arguments: [
      tx.object(agreementId),
      tx.object(SUI_CLOCK_OBJECT_ID),
    ],
  })

  return tx
}

// ─── Dispute ──────────────────────────────────────────────────────────────────

/**
 * Build a PTB that raises a dispute on an active agreement.
 * Either party can raise a dispute.
 */
export function buildRaiseDispute(
  config: NetworkConfig,
  params: RaiseDisputeParams,
): Transaction {
  const tx = new Transaction()

  tx.moveCall({
    target:    `${config.packageId}::pacta::raise_dispute`,
    arguments: [
      tx.object(params.agreementId),
      tx.pure.vector("u8", Array.from(new TextEncoder().encode(params.reason))),
    ],
  })

  return tx
}

/**
 * Build a PTB that resolves a dispute.
 * Only the arbiter can call this. resolution: 0 = favour party A, 1 = favour party B.
 */
export function buildResolveDispute(
  config: NetworkConfig,
  params: ResolveDisputeParams,
): Transaction {
  const tx = new Transaction()

  tx.moveCall({
    target:    `${config.packageId}::pacta::resolve_dispute`,
    arguments: [
      tx.object(params.agreementId),
      tx.pure.u8(params.resolution),
    ],
  })

  return tx
}

// ─── Claiming ─────────────────────────────────────────────────────────────────

/**
 * Build a PTB that claims a coin from a finalized agreement.
 * Each party calls this to pull their allocated coin to their wallet.
 */
export function buildClaimCoin(
  config: NetworkConfig,
  params: ClaimCoinParams,
): Transaction {
  const tx = new Transaction()

  tx.moveCall({
    target:         `${config.packageId}::pacta::claim_coin`,
    typeArguments:  [params.coinType],
    arguments:      [tx.object(params.agreementId)],
  })

  return tx
}

// ─── Utility ──────────────────────────────────────────────────────────────────

/**
 * Convert a hex string (with or without 0x prefix) to a byte array.
 */
function hexToBytes(hex: string): number[] {
  const clean = hex.startsWith("0x") ? hex.slice(2) : hex
  if (clean.length === 0) return []
  const bytes: number[] = []
  for (let i = 0; i < clean.length; i += 2) {
    bytes.push(parseInt(clean.slice(i, i + 2), 16))
  }
  return bytes
}
