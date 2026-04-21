# fee_vault_client

A pure-Dart client for the [`fee_vault`](../programs/fee_vault) Solana program.

This package exists to demonstrate, in isolation, the patterns needed to build a
gasless SPL transfer from a mobile client without a heavyweight SDK:

- **`MnemonicWallet`** — BIP39 mnemonic generation, validation (off the main isolate), and Ed25519 HD key derivation that matches what `Ed25519HDKeyPair.fromMnemonic` produces.
- **`anchorDiscriminator(...)`** — the 8-byte instruction prefix Anchor uses (`sha256("global:<name>")[..8]`).
- **`FeeVaultInstructions`** — instruction builders for `initialize`, `top_up_sponsor`, and `sweep_remainder`. Account meta order is verified against the program's `#[derive(Accounts)]` structs.
- **`computeBudget`** — `setComputeUnitLimit` and `setComputeUnitPrice` builders that talk to the well-known `ComputeBudget111…` program.
- **`GaslessTransactionBuilder`** — assembles a transaction where the **sponsor pays the fee** but the **user signs** the SPL transfer instruction. Both signatures are placed at the correct positions in the compiled message.
- **`FeeVaultClient`** — high-level facade: `sendGaslessSplTransfer(...)` builds the full atomic transaction `[topUp, setComputeUnitLimit, setComputeUnitPrice, splTransfer]`, signs it, and submits it.

The package has no Flutter dependency, so the unit tests run in CI under `dart test` without any platform setup.

## Install

```yaml
dependencies:
  fee_vault_client:
    git:
      url: https://github.com/<your-org>/<your-repo>.git
      path: client-dart
```

## Quick start

```dart
import 'package:fee_vault_client/fee_vault_client.dart';
import 'package:solana/solana.dart';

final client = FeeVaultClient(
  rpcUrl: Uri.parse('https://api.devnet.solana.com'),
  programId: Ed25519HDPublicKey.fromBase58('<your fee_vault program id>'),
  vaultPda: Ed25519HDPublicKey.fromBase58('<initialized vault PDA>'),
);

final user = await MnemonicWallet.fromMnemonic('<12 words>');
final sponsor = await Ed25519HDKeyPair.fromPrivateKeyBytes(privateKey: <32 bytes>);

final signature = await client.sendGaslessSplTransfer(
  user: user,
  sponsor: sponsor,
  destination: '<recipient base58>',
  mint: 'Gh9ZwEmdLJ8DscKNTkTqPbNwLNNBjuSzaG9Vp2KGtKJr', // devnet USDC
  amount: BigInt.from(1_000_000), // 1.000000 USDC
);

print('https://solscan.io/tx/$signature?cluster=devnet');
```

The recipient must already have an associated token account for the mint.
ATA creation is intentionally not part of v1 (see [SECURITY.md](../docs/SECURITY.md)).

## Test

```bash
dart pub get
dart test
```

A devnet smoke-test example is in [`example/gasless_transfer_example.dart`](example/gasless_transfer_example.dart).
