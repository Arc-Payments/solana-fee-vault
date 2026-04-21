# fee-vault

A production-grade Solana program and Dart client for **gasless SPL token payments** using a PDA-based fee vault.

This repository contains a focused, security-vetted subset of the on-chain and mobile-client code that powers a real LATAM stablecoin payments app. The full app — including the proximity-payment transport layer and operational infrastructure — is intentionally not part of this repo.

## What's in here

- **`programs/fee_vault/`** — an Anchor program that escrows SOL in a PDA and lets a designated authority top up a sponsor account just enough to cover transaction fees, then sweep the remainder back. Includes per-transaction limits, daily limits, and emergency pause controls.
- **`tests/fee_vault.ts`** — Anchor TypeScript test suite. Includes the negative tests that prove the auth model (`has_one = authority`) actually rejects unauthorized callers.
- **`client-dart/`** — a standalone Dart package that demonstrates the client side: BIP39 mnemonic + Ed25519 HD key derivation, manual Anchor instruction encoding (discriminator + Borsh args), compute-budget instructions, and the multi-signature transaction assembly pattern (user authorizes the SPL transfer, sponsor pays the fee).

## Why this design

A naive "gasless" implementation hands the user a pre-funded throwaway keypair. That bleeds rent and creates a UX with extra wallets to manage. The pattern here keeps a single program-owned PDA as the source of fee SOL, transfers exactly enough to a sponsor account at the start of each user transaction, and (optionally) sweeps the unused remainder back at the end. Phantom, Jupiter, and Magic Eden use variants of the same approach.

Per-transaction and per-day limits are enforced on-chain, so a compromised sponsor or authority key has bounded blast radius rather than draining the vault. The `emergency_authority` is a separate signer that can pause all top-ups instantly without needing to rotate the main authority.

## Quick start

### Build the program

Requires [Anchor](https://www.anchor-lang.com/docs/installation) `0.32.1` and Solana CLI `3.x` (CI pins `v3.1.13`, which ships platform-tools `v1.52` / Rust 1.85, needed for transitive deps that use the 2024 edition).

```bash
anchor build
anchor test
```

### Use the Dart client

```bash
cd client-dart
dart pub get
dart test
```

To run the end-to-end example against devnet:

```bash
export FEE_VAULT_PROGRAM_ID="<your deployed program id>"
export FEE_VAULT_VAULT_PDA="<your initialized vault PDA>"
export FEE_VAULT_AUTHORITY_KEY="<base64 of the 64-byte authority secret key>"
export FEE_VAULT_USER_MNEMONIC="<12 or 24 word BIP39 mnemonic>"
export FEE_VAULT_DESTINATION="<recipient solana address>"
export FEE_VAULT_USDC_MINT="Gh9ZwEmdLJ8DscKNTkTqPbNwLNNBjuSzaG9Vp2KGtKJr"  # devnet USDC

dart run example/gasless_transfer_example.dart
```

## Documentation

- [Architecture](docs/ARCHITECTURE.md) — sequence diagram of the top-up / transfer / sweep flow and account relationships.
- [Security model](docs/SECURITY.md) — threat model, why each authority check is there, what the limits buy you.
- [Pre-publish checklist](PRE_PUBLISH_CHECKLIST.md) — for forks before pushing to a new repo.

## What is intentionally not in this repo

The proximity-payment transport, the production backend, fiat onramp integrations, the wallet UI, the LATAM-specific business logic, and any operational keys or RPC API credentials live in a private repository. This project is the on-chain and crypto-client foundation only.

## License

MIT — see [LICENSE](LICENSE).
