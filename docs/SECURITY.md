# Security model

## Threat model

We assume the following actors and capabilities:

- **End user** holds the BIP39 mnemonic for their wallet on their device. They
  authorize each token transfer.
- **Sponsor / operational authority** is a hot key the operator runs in a
  serverless function or backend. It signs every `top_up_sponsor` and pays the
  Solana network fee for the surrounding transaction.
- **Emergency authority** is a cold key the operator can reach out-of-band
  (hardware wallet, multisig, paper backup). It is used only to pause the
  program when something is wrong.
- **Attacker** can submit arbitrary transactions to the cluster, observe all
  on-chain state, run their own Solana programs, and (in the worst case)
  exfiltrate the operational authority key.

## What each constraint defends against

### `has_one = authority` on `top_up_sponsor` and `sweep_remainder`

The `top_up_sponsor` instruction transfers SOL from the vault PDA to a
caller-chosen `sponsor` account. Without an authority check, anyone could
submit a transaction whose `sponsor` is their own wallet and drain the vault
up to `max_per_transaction` per call until they hit `max_daily_spend`. The
`has_one = authority` constraint, paired with `Signer<'info>` on the authority
account, makes Anchor reject any caller whose signer is not the pubkey
recorded on the vault during `initialize`. See
[`programs/fee_vault/src/lib.rs`](../programs/fee_vault/src/lib.rs).

The matching negative test is
[`tests/fee_vault.ts`](../tests/fee_vault.ts) `top_up_sponsor rejects an
unauthorized signer`. If you remove `has_one = authority` from the program,
that test fails immediately, which is the point.

### `sponsor.owner == system_program::ID`

We require the `sponsor` account to be system-owned. Two reasons:

1. The Solana fee payer **must** be system-owned; passing anything else makes
   the surrounding transaction invalid. This check fails fast with a clear
   error instead of a confusing runtime error.
2. It blocks an attacker from passing in another program's PDA as the sponsor
   to confuse downstream programs about the source of funds.

### Per-transaction and daily limits

`max_per_transaction` and `max_daily_spend` cap the blast radius if the
operational `authority` is compromised. The attacker can drain at most one
day's worth before the emergency authority flips the pause; with sensible
limits (a few cents per tx, a few dollars per day) that is bounded enough to
notice and rotate.

The reset path uses a `current_day = unix_timestamp / 86400` comparison and
the same `checked_add` arithmetic as the normal path, so there is no overflow
or "first call after reset" gotcha.

### Two separate authorities

Splitting operational signing (`authority`) from incident response
(`emergency_authority`) means you can keep the latter on a hardware wallet or
in a multisig and never need to bring it online for routine top-ups. Pausing
does not need to coordinate with key rotation: the `emergency_authority`
flips the pause flag, the operational key gets rotated separately via
`update_authority`-style flows (not yet in v1, see open issues).

### Manual lamport mutation on a program-owned account

Inside `top_up_sponsor` we mutate lamports directly:

```rust
**vault_info.try_borrow_mut_lamports()? -= max_lamports;
**sponsor_info.try_borrow_mut_lamports()? += max_lamports;
```

This is the canonical Anchor pattern when the **source** account is
program-owned. A `system_program::transfer` CPI would fail because the system
program rejects transfers from accounts whose owner is not the system program
itself. The values are checked with `checked_sub` / `checked_add` to avoid
silent wraparound; both writes happen inside the same instruction so
`top_up_sponsor` is atomic — either both moves land or neither does.

### `MIN_SPONSOR_BALANCE` floor on sweeps

`sweep_remainder` leaves at least `MIN_SPONSOR_BALANCE` (0.001 SOL) in the
sponsor. Two reasons:

1. The sponsor account is system-owned and must stay rent-exempt; sweeping it
   to zero would close it and force a re-create on the next transaction
   (unnecessary cost and one extra failure mode).
2. It bounds how much "lost" sponsor balance accumulates if the off-chain
   sweeper cron fails for a while: at most one floor's worth.

## What is **not** in scope for v1

These are real concerns that the v1 program does not solve. They're listed
here so reviewers (and you) know what's missing on purpose.

- **Authority rotation.** There is no `update_authority` instruction. Rotating
  the operational key today means deploying a new vault with a new authority
  and migrating funds. v2 should add a single `update_authority` ix gated by
  the current `authority` (or a multisig).
- **Multisig authorities.** `authority` and `emergency_authority` are single
  pubkeys. Wrapping them with Squads or Realms is straightforward and is
  recommended for any non-toy deployment.
- **Replay across programs.** The discriminator + the `has_one` check are
  enough on Solana because each program owns its own state and ID. There is
  no cross-program "wrong vault" risk; an attacker cannot point this program
  at someone else's `FeeVault` PDA, because the PDA is derived from this
  program's ID.
- **ATA creation as part of the gasless transfer.** Creating the destination
  associated token account costs ~0.002 SOL of rent that the sponsor would
  have to cover. The Dart client checks for the ATA's existence and refuses
  the transfer if it's missing, rather than silently absorbing the cost.
- **Time-based daily reset testing.** `solana-test-validator` does not allow
  warping the wall clock, so the daily reset path is reviewed in source
  rather than in the TS test suite. Use `solana-bankrun` if you want to
  exercise it programmatically.

## Operational guidance

If you deploy this program for real:

1. Generate `authority` and `emergency_authority` on different machines.
   Treat `emergency_authority` as cold; never load it onto the API server.
2. Set `max_per_transaction` to roughly `2 × actual_fee` (the fee plus a
   safety margin), and `max_daily_spend` to roughly `expected_volume × 1.5`.
   Tighter is better.
3. Monitor vault balance. If it drops faster than your model predicts, that
   is the signal to pause and investigate before rotating keys.
4. Rotate the operational authority on a schedule, not just after incidents.
   Write the runbook that does it before you need it.
