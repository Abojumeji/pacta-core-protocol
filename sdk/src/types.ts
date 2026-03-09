// ─── Agreement States ────────────────────────────────────────────────────────
// Mirrors the STATE_* constants in pacta.move

export const AgreementState = {
  Created:         0,
  Active:          1,
  Settled:         2,
  Cancelled:       3,
  Disputed:        4,
  DisputeResolved: 5,
} as const

export type AgreementState = typeof AgreementState[keyof typeof AgreementState]

// ─── Release Condition Bitmask ────────────────────────────────────────────────
// Mirrors the COND_* constants in pacta.move
// Combine with bitwise OR — e.g. BOTH_DEPOSITED | BOTH_APPROVED

export const Condition = {
  ADeposited: 0x01,
  BDeposited: 0x02,
  AApproved:  0x04,
  BApproved:  0x08,
  Timelock:   0x10,
} as const

// Common presets
export const ConditionPreset = {
  // Both deposit, both approve — standard two-party escrow
  FullConsent:    0x01 | 0x02 | 0x04 | 0x08,
  // Both deposit only — no approval step needed
  DepositOnly:    0x01 | 0x02,
  // Both deposit + timelock
  TimelockEscrow: 0x01 | 0x02 | 0x10,
} as const

// ─── Party IDs ────────────────────────────────────────────────────────────────

export const Party = {
  A: 0,
  B: 1,
} as const

export type Party = typeof Party[keyof typeof Party]

// ─── Network Config ───────────────────────────────────────────────────────────

export type Network = "localnet" | "testnet" | "mainnet"

export interface NetworkConfig {
  /** Deployed Pacta package ID */
  packageId: string
  /** PactaRegistry shared object ID */
  registryId: string
  /** Sui RPC URL */
  rpcUrl: string
}

export const NETWORK_CONFIGS: Record<Network, NetworkConfig> = {
  localnet: {
    packageId: "0x0",
    registryId: "0x0",
    rpcUrl:    "http://127.0.0.1:9000",
  },
  testnet: {
    packageId:  "0xc69e192b8cc1ace8b785c467970542a2dba7a5c2e21dcde55ad668af997d086f",
    registryId: "0xd53ca2b8b780b5b9c30417a83296f00f90ac21a9a8a29463ccfae1829d0af2b5",
    rpcUrl:    "https://fullnode.testnet.sui.io:443",
  },
  mainnet: {
    packageId: "0x0",   // fill in after mainnet deploy
    registryId: "0x0",  // fill in after mainnet deploy
    rpcUrl:    "https://fullnode.mainnet.sui.io:443",
  },
}

// ─── On-Chain Struct Mirrors ──────────────────────────────────────────────────

/** Agreement as returned by sui client object queries */
export interface Agreement {
  id:                 string
  version:            number
  creator:            string
  partyA:             string
  partyB:             string
  arbiter:            string
  state:              AgreementState
  releaseConditions:  number
  aDeposited:         boolean
  bDeposited:         boolean
  aApproved:          boolean
  bApproved:          boolean
  aCancelConsent:     boolean
  bCancelConsent:     boolean
  aObjCount:          number
  bObjCount:          number
  activeSlots:        number
  hookAttached:       boolean
  registryRecorded:   boolean
  aRecipient:         string
  bRecipient:         string
  termsHash:          string
  expiryMs:           bigint
  unlockTimeMs:       bigint
  createdAtMs:        bigint
  settledAtMs:        bigint
  metadata:           string
}

export interface PactaRegistry {
  id:               string
  version:          number
  totalAgreements:  bigint
  totalSettled:     bigint
  totalCancelled:   bigint
  totalDisputed:    bigint
}

// ─── Input Types ──────────────────────────────────────────────────────────────

export interface CreateAgreementParams {
  partyA:             string
  partyB:             string
  arbiter:            string
  /** Release condition bitmask. Use ConditionPreset or combine Condition flags */
  releaseConditions:  number
  /** SHA3-256 hash of the off-chain agreement document, as hex string */
  termsHash:          string
  /** Unix timestamp ms after which the agreement can be cancelled. 0 = no expiry */
  expiryMs:           bigint
  /** Unix timestamp ms before which settlement cannot happen. 0 = no timelock */
  unlockTimeMs:       bigint
  /** Optional app-specific metadata as hex string */
  metadata?:          string
}

export interface DepositCoinParams {
  agreementId:  string
  coinObjectId: string
  coinType:     string
}

export interface ApproveParams {
  agreementId: string
}

export interface SettleParams {
  agreementId: string
}

export interface CancelParams {
  agreementId: string
}

export interface MutualCancelParams {
  agreementId: string
}

export interface RaiseDisputeParams {
  agreementId: string
  /** Reason for raising the dispute, as UTF-8 string */
  reason: string
}

export interface ResolveDisputeParams {
  agreementId: string
  /** 0 = rule in favour of party A, 1 = rule in favour of party B */
  resolution: 0 | 1
}

export interface ClaimCoinParams {
  agreementId: string
  coinType:    string
}

export interface SetPartyBParams {
  agreementId: string
  newPartyB:   string
}
