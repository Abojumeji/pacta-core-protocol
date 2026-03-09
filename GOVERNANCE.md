# Pacta Protocol — Governance & Key Management

## Overview

Pacta has two privileged keys that must be secured before mainnet deployment:

| Key | What it controls | Lives in |
|---|---|---|
| `AdminCap` | Registry counters, future protocol parameters | `pacta::pacta` |
| Timelock admin | Package upgrade proposals | `pacta::timelock` |

Both keys are transferred to a **Sui multisig wallet** at deploy time. This means no single person can make unilateral changes — a majority of the team must sign every admin action.

---

## Why Multisig

Without multisig:
- One compromised laptop = attacker controls the protocol
- One person goes offline = nobody can manage the protocol
- Builders ask "who controls this?" and the answer is "one person" — not infrastructure-grade

With 3-of-5 multisig:
- Attacker must compromise 3 separate devices simultaneously
- Team can lose 2 members and still operate
- Builders can verify on-chain that no single party has unilateral control

---

## Step 1 — Create the Multisig Wallet

A Sui multisig address is derived from a set of public keys and a threshold.

### Collect public keys from each signer

Each team member runs this on their own machine:

```bash
sui keytool generate ed25519
```

This outputs a public key. Share only the public key — never the private key.

### Create the multisig address

On any machine, combine the public keys into a multisig address:

```bash
sui keytool multi-sig-address \
  --pks <PUBKEY_1> <PUBKEY_2> <PUBKEY_3> <PUBKEY_4> <PUBKEY_5> \
  --weights 1 1 1 1 1 \
  --threshold 3
```

This prints a multisig address like `0xABC...`. Save it — this is the governance address.

**Recommended setup:** 5 signers, threshold 3 (3-of-5). Adjust to your team size.

---

## Step 2 — Deploy the Package

```bash
sui client publish --gas-budget 100000000
```

After publishing you will have:
- A package ID (e.g. `0xPKG...`)
- An `AdminCap` object in your deployer wallet
- An `UpgradeCap` object in your deployer wallet
- A `PactaRegistry` shared object

---

## Step 3 — Wrap the UpgradeCap in the Timelock

Do this in the same session as deploy, before handing off anything.

```bash
sui client call \
  --package <PACKAGE_ID> \
  --module timelock \
  --function wrap \
  --args <UPGRADE_CAP_ID> <MULTISIG_ADDRESS> \
  --gas-budget 10000000
```

This locks the `UpgradeCap` inside a `TimelockUpgradeCap` shared object. The raw
`UpgradeCap` is gone — upgrades now require the 14-day timelock process.

---

## Step 4 — Transfer AdminCap to the Multisig

```bash
sui client call \
  --package <PACKAGE_ID> \
  --module pacta \
  --function transfer_admin_cap \
  --args <ADMIN_CAP_ID> <MULTISIG_ADDRESS> \
  --gas-budget 10000000
```

After this, your deployer wallet has no special privileges. Both keys are now
controlled by the 3-of-5 multisig.

---

## Step 5 — Transfer the Timelock Admin to the Multisig

```bash
sui client call \
  --package <PACKAGE_ID> \
  --module timelock \
  --function transfer_admin \
  --args <TIMELOCK_CAP_ID> <MULTISIG_ADDRESS> \
  --gas-budget 10000000
```

Now both `AdminCap` and the timelock admin are in the multisig wallet.

---

## Step 6 — Verify On-Chain

Confirm the state is correct before announcing mainnet:

```bash
# Check AdminCap owner
sui client object <ADMIN_CAP_ID>
# Owner field must show the multisig address

# Check timelock admin
sui client object <TIMELOCK_CAP_ID>
# admin field must show the multisig address
```

---

## Day-to-Day Admin Operations

### Making a registry update (e.g. record_settled)

1. One team member constructs the PTB with the desired admin call
2. They sign with their key and share the partial signature
3. Two more signers add their signatures
4. Any signer submits the combined multisig transaction

```bash
# Each signer signs independently
sui keytool multi-sig-sign \
  --tx-bytes <TX_BYTES> \
  --signer-sk <THEIR_PRIVATE_KEY>

# Combine 3 signatures and submit
sui client execute-signed-tx \
  --tx-bytes <TX_BYTES> \
  --signatures <SIG_1> <SIG_2> <SIG_3>
```

---

## Proposing a Package Upgrade

This is a three-step process spread over 14+ days.

### Day 0 — Propose

One team member proposes, 3 signatures required:

```bash
# Get the digest of the new package
sui client upgrade --dry-run --gas-budget 100000000
# Copy the digest from the output

# Propose the upgrade (requires multisig)
sui client call \
  --package <PACKAGE_ID> \
  --module timelock \
  --function propose_upgrade \
  --args <TIMELOCK_CAP_ID> 0 <DIGEST> <CLOCK_ID> \
  --gas-budget 10000000
```

The proposal is now publicly visible on-chain. Anyone can see it.

### Days 1-14 — Waiting Period

- Announce the proposal publicly (Twitter, Discord, docs)
- Share the digest so builders can verify what is changing
- Collect community feedback
- If anything looks wrong, call `cancel_upgrade` (requires multisig)

### Day 14+ — Execute

```bash
sui client upgrade \
  --upgrade-capability <TIMELOCK_CAP_ID> \
  --gas-budget 100000000
```

---

## Emergency: Cancelling a Malicious Proposal

If a team member's wallet is compromised and they propose a malicious upgrade:

1. The remaining signers have 14 days to act
2. Any 3 signers call `cancel_upgrade` to remove the proposal
3. Then call `transfer_admin` on the timelock to rotate the admin to a new multisig
   address that excludes the compromised signer

```bash
sui client call \
  --package <PACKAGE_ID> \
  --module timelock \
  --function cancel_upgrade \
  --args <TIMELOCK_CAP_ID> \
  --gas-budget 10000000
```

---

## Future: Burning the UpgradeCap

After the formal security audit passes, the team may vote to make the protocol
permanently immutable by burning the upgrade capability. This means no future
upgrades are possible — ever.

This is the highest trust level for builders. Only do this when the protocol is
fully stable and audited.

The mechanism: transfer the `TimelockUpgradeCap` to the zero address `@0x0`,
or add a `burn_upgrade_cap` function during a final upgrade that destroys it.

---

## Deployment Checklist

Before announcing mainnet, confirm all of the following:

- [ ] Package published successfully
- [ ] `UpgradeCap` wrapped in `TimelockUpgradeCap` (raw cap is gone)
- [ ] `AdminCap` transferred to multisig address
- [ ] Timelock admin transferred to multisig address
- [ ] Both transfers verified on-chain via `sui client object`
- [ ] At least 3 team members have tested signing a multisig transaction
- [ ] Multisig address announced publicly so builders can verify
- [ ] ARCHITECTURE.md updated with deployed package ID and object IDs
