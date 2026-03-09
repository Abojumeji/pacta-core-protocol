import { SuiClient } from "@mysten/sui/client"
import { Transaction } from "@mysten/sui/transactions"
import {
  Network,
  NetworkConfig,
  NETWORK_CONFIGS,
  Agreement,
  PactaRegistry,
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
import {
  buildCreateAgreement,
  buildSetPartyB,
  buildDepositCoin,
  buildApprove,
  buildSettle,
  buildCancel,
  buildMutualCancel,
  buildCancelExpired,
  buildRaiseDispute,
  buildResolveDispute,
  buildClaimCoin,
} from "./transactions"

// ─── Signer Interface ─────────────────────────────────────────────────────────
// PactaClient does not depend on any specific wallet library.
// Pass in any signer that satisfies this interface — browser wallet (dApp Kit),
// Keypair, or multisig signer.

export interface Signer {
  /** The Sui address of the signer */
  address: string
  /** Sign and execute a transaction, returning the digest */
  signAndExecuteTransaction(tx: Transaction): Promise<{ digest: string }>
}

// ─── Client Options ───────────────────────────────────────────────────────────

export interface PactaClientOptions {
  /** "localnet" | "testnet" | "mainnet" */
  network: Network
  /** Override any network defaults (e.g. custom RPC URL after deploy) */
  overrides?: Partial<NetworkConfig>
}

// ─── PactaClient ──────────────────────────────────────────────────────────────

export class PactaClient {
  readonly config:  NetworkConfig
  readonly suiClient: SuiClient

  constructor(options: PactaClientOptions) {
    this.config = {
      ...NETWORK_CONFIGS[options.network],
      ...options.overrides,
    }
    this.suiClient = new SuiClient({ url: this.config.rpcUrl })
  }

  // ─── Read: Fetch On-Chain State ────────────────────────────────────────────

  /**
   * Fetch an Agreement object by its ID.
   */
  async getAgreement(agreementId: string): Promise<Agreement> {
    const obj = await this.suiClient.getObject({
      id:      agreementId,
      options: { showContent: true },
    })

    if (!obj.data?.content || obj.data.content.dataType !== "moveObject") {
      throw new Error(`Object ${agreementId} not found or is not a Move object`)
    }

    const fields = obj.data.content.fields as Record<string, unknown>
    return parseAgreement(agreementId, fields)
  }

  /**
   * Fetch the PactaRegistry shared object.
   */
  async getRegistry(): Promise<PactaRegistry> {
    const obj = await this.suiClient.getObject({
      id:      this.config.registryId,
      options: { showContent: true },
    })

    if (!obj.data?.content || obj.data.content.dataType !== "moveObject") {
      throw new Error("PactaRegistry not found — check registryId in config")
    }

    const fields = obj.data.content.fields as Record<string, unknown>
    return {
      id:              this.config.registryId,
      version:         Number(fields["version"]),
      totalAgreements: BigInt(String(fields["total_agreements"])),
      totalSettled:    BigInt(String(fields["total_settled"])),
      totalCancelled:  BigInt(String(fields["total_cancelled"])),
      totalDisputed:   BigInt(String(fields["total_disputed"])),
    }
  }

  /**
   * Fetch all Agreement IDs created by a given address, using event queries.
   */
  async getAgreementsByCreator(creator: string): Promise<string[]> {
    const events = await this.suiClient.queryEvents({
      query: {
        MoveEventType: `${this.config.packageId}::pacta::AgreementCreated`,
      },
    })

    return events.data
      .filter((e) => {
        const fields = e.parsedJson as Record<string, unknown>
        return fields["creator"] === creator
      })
      .map((e) => {
        const fields = e.parsedJson as Record<string, unknown>
        return String(fields["agreement_id"])
      })
  }

  // ─── Write: Build + Execute ────────────────────────────────────────────────

  /**
   * Create a new shared agreement on-chain.
   *
   * @example
   * const result = await pacta.createAgreement(signer, {
   *   partyA:            signer.address,
   *   partyB:            "0xBOB...",
   *   arbiter:           "0xARBITER...",
   *   releaseConditions: ConditionPreset.FullConsent,
   *   termsHash:         "0xDEADBEEF...",
   *   expiryMs:          0n,
   *   unlockTimeMs:      0n,
   * })
   */
  async createAgreement(
    signer: Signer,
    params: CreateAgreementParams,
  ): Promise<{ digest: string }> {
    const tx = buildCreateAgreement(this.config, params)
    return signer.signAndExecuteTransaction(tx)
  }

  /**
   * Update party B's address before they have deposited.
   */
  async setPartyB(
    signer: Signer,
    params: SetPartyBParams,
  ): Promise<{ digest: string }> {
    const tx = buildSetPartyB(this.config, params)
    return signer.signAndExecuteTransaction(tx)
  }

  /**
   * Deposit a coin into the agreement.
   * The contract resolves whether you are party A or B from your address.
   */
  async depositCoin(
    signer: Signer,
    params: DepositCoinParams,
  ): Promise<{ digest: string }> {
    const tx = buildDepositCoin(this.config, params)
    return signer.signAndExecuteTransaction(tx)
  }

  /**
   * Record your approval to release funds.
   */
  async approve(
    signer: Signer,
    params: ApproveParams,
  ): Promise<{ digest: string }> {
    const tx = buildApprove(this.config, params)
    return signer.signAndExecuteTransaction(tx)
  }

  /**
   * Settle the agreement and release funds to both parties.
   * Any address can call this once all conditions are satisfied.
   */
  async settle(
    signer: Signer,
    params: SettleParams,
  ): Promise<{ digest: string }> {
    const tx = buildSettle(this.config, params)
    return signer.signAndExecuteTransaction(tx)
  }

  /**
   * Cancel the agreement.
   */
  async cancel(
    signer: Signer,
    params: CancelParams,
  ): Promise<{ digest: string }> {
    const tx = buildCancel(this.config, params)
    return signer.signAndExecuteTransaction(tx)
  }

  /**
   * Signal your consent to a mutual cancel.
   * Both parties must call this to complete the cancellation.
   */
  async mutualCancel(
    signer: Signer,
    params: MutualCancelParams,
  ): Promise<{ digest: string }> {
    const tx = buildMutualCancel(this.config, params)
    return signer.signAndExecuteTransaction(tx)
  }

  /**
   * Cancel an expired agreement. Anyone can trigger this after the expiry time.
   */
  async cancelExpired(
    signer: Signer,
    agreementId: string,
  ): Promise<{ digest: string }> {
    const tx = buildCancelExpired(this.config, agreementId)
    return signer.signAndExecuteTransaction(tx)
  }

  /**
   * Raise a dispute on an active agreement.
   */
  async raiseDispute(
    signer: Signer,
    params: RaiseDisputeParams,
  ): Promise<{ digest: string }> {
    const tx = buildRaiseDispute(this.config, params)
    return signer.signAndExecuteTransaction(tx)
  }

  /**
   * Resolve a dispute. Only the arbiter can call this.
   */
  async resolveDispute(
    signer: Signer,
    params: ResolveDisputeParams,
  ): Promise<{ digest: string }> {
    const tx = buildResolveDispute(this.config, params)
    return signer.signAndExecuteTransaction(tx)
  }

  /**
   * Claim your allocated coin from a settled or resolved agreement.
   */
  async claimCoin(
    signer: Signer,
    params: ClaimCoinParams,
  ): Promise<{ digest: string }> {
    const tx = buildClaimCoin(this.config, params)
    return signer.signAndExecuteTransaction(tx)
  }

  // ─── PTB Builders (advanced use) ──────────────────────────────────────────
  // Return raw Transaction objects for apps that need to compose multiple
  // operations into one PTB before signing.

  buildCreateAgreement  = (p: CreateAgreementParams)  => buildCreateAgreement(this.config, p)
  buildSetPartyB        = (p: SetPartyBParams)         => buildSetPartyB(this.config, p)
  buildDepositCoin      = (p: DepositCoinParams)       => buildDepositCoin(this.config, p)
  buildApprove          = (p: ApproveParams)           => buildApprove(this.config, p)
  buildSettle           = (p: SettleParams)            => buildSettle(this.config, p)
  buildCancel           = (p: CancelParams)            => buildCancel(this.config, p)
  buildMutualCancel     = (p: MutualCancelParams)      => buildMutualCancel(this.config, p)
  buildCancelExpired    = (agreementId: string)        => buildCancelExpired(this.config, agreementId)
  buildRaiseDispute     = (p: RaiseDisputeParams)      => buildRaiseDispute(this.config, p)
  buildResolveDispute   = (p: ResolveDisputeParams)    => buildResolveDispute(this.config, p)
  buildClaimCoin        = (p: ClaimCoinParams)         => buildClaimCoin(this.config, p)
}

// ─── Internal Parser ──────────────────────────────────────────────────────────

function parseAgreement(id: string, f: Record<string, unknown>): Agreement {
  return {
    id,
    version:           Number(f["version"]),
    creator:           String(f["creator"]),
    partyA:            String(f["party_a"]),
    partyB:            String(f["party_b"]),
    arbiter:           String(f["arbiter"]),
    state:             Number(f["state"]) as Agreement["state"],
    releaseConditions: Number(f["release_conditions"]),
    aDeposited:        Boolean(f["a_deposited"]),
    bDeposited:        Boolean(f["b_deposited"]),
    aApproved:         Boolean(f["a_approved"]),
    bApproved:         Boolean(f["b_approved"]),
    aCancelConsent:    Boolean(f["a_cancel_consent"]),
    bCancelConsent:    Boolean(f["b_cancel_consent"]),
    aObjCount:         Number(f["a_obj_count"]),
    bObjCount:         Number(f["b_obj_count"]),
    activeSlots:       Number(f["active_slots"]),
    hookAttached:      Boolean(f["hook_attached"]),
    registryRecorded:  Boolean(f["registry_recorded"]),
    aRecipient:        String(f["a_recipient"]),
    bRecipient:        String(f["b_recipient"]),
    termsHash:         bytesToHex(f["terms_hash"] as number[]),
    expiryMs:          BigInt(String(f["expiry_ms"])),
    unlockTimeMs:      BigInt(String(f["unlock_time_ms"])),
    createdAtMs:       BigInt(String(f["created_at_ms"])),
    settledAtMs:       BigInt(String(f["settled_at_ms"])),
    metadata:          bytesToHex(f["metadata"] as number[]),
  }
}

function bytesToHex(bytes: number[] | undefined): string {
  if (!bytes || bytes.length === 0) return "0x"
  return "0x" + bytes.map((b) => b.toString(16).padStart(2, "0")).join("")
}
