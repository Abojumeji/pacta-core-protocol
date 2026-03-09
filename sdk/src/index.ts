// ─── Main Client ──────────────────────────────────────────────────────────────
export { PactaClient } from "./client"
export type { Signer, PactaClientOptions } from "./client"

// ─── Types ────────────────────────────────────────────────────────────────────
export {
  AgreementState,
  Condition,
  ConditionPreset,
  Party,
  NETWORK_CONFIGS,
} from "./types"

export type {
  Network,
  NetworkConfig,
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

// ─── PTB Builders (advanced / composable use) ────────────────────────────────
export {
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
