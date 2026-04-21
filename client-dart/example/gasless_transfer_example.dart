// Devnet end-to-end smoke test for `FeeVaultClient.sendGaslessSplTransfer`.
//
// Run:
//   export FEE_VAULT_PROGRAM_ID=...
//   export FEE_VAULT_VAULT_PDA=...
//   export FEE_VAULT_AUTHORITY_KEY=<base64 64-byte secret key, sponsor + authority>
//   export FEE_VAULT_USER_MNEMONIC="<12 or 24 words>"
//   export FEE_VAULT_DESTINATION=<recipient base58 address>
//   export FEE_VAULT_USDC_MINT=Gh9ZwEmdLJ8DscKNTkTqPbNwLNNBjuSzaG9Vp2KGtKJr
//   export FEE_VAULT_AMOUNT=1000000   # 1.000000 USDC (6 decimals)
//   export FEE_VAULT_RPC_URL=https://api.devnet.solana.com
//   dart run example/gasless_transfer_example.dart
//
// Prerequisites:
//   * The vault PDA must already be initialized (run `anchor test` against the
//     program first, or initialize manually).
//   * The vault must hold > FEE_VAULT_MAX_FEE_LAMPORTS (default 10_000) lamports.
//   * The user's wallet must have a USDC balance >= FEE_VAULT_AMOUNT.
//   * The destination must already have an associated token account for the mint.

import 'dart:convert';
import 'dart:io';

import 'package:fee_vault_client/fee_vault_client.dart';
import 'package:solana/solana.dart';

Future<void> main() async {
  final env = Platform.environment;

  String require(String name) {
    final v = env[name];
    if (v == null || v.isEmpty) {
      stderr.writeln('Missing required env var: $name');
      exit(64);
    }
    return v;
  }

  final programId =
      Ed25519HDPublicKey.fromBase58(require('FEE_VAULT_PROGRAM_ID'));
  final vaultPda =
      Ed25519HDPublicKey.fromBase58(require('FEE_VAULT_VAULT_PDA'));
  final authorityKeyBase64 = require('FEE_VAULT_AUTHORITY_KEY');
  final userMnemonic = require('FEE_VAULT_USER_MNEMONIC');
  final destination = require('FEE_VAULT_DESTINATION');
  final mint = require('FEE_VAULT_USDC_MINT');
  final amount = BigInt.parse(require('FEE_VAULT_AMOUNT'));
  final rpcUrl =
      Uri.parse(env['FEE_VAULT_RPC_URL'] ?? 'https://api.devnet.solana.com');
  final maxFeeLamports =
      int.parse(env['FEE_VAULT_MAX_FEE_LAMPORTS'] ?? '10000');

  // Decode the authority/sponsor secret key. Anchor and `solana-keygen` emit
  // 64-byte arrays where the second 32 bytes are the public key. We need the
  // first 32 bytes (the seed/private key).
  final keyBytes = base64.decode(authorityKeyBase64);
  if (keyBytes.length != 64 && keyBytes.length != 32) {
    throw FormatException(
      'FEE_VAULT_AUTHORITY_KEY must decode to 32 or 64 bytes, got ${keyBytes.length}',
    );
  }
  final secretKey = keyBytes.sublist(0, 32);
  final sponsor =
      await Ed25519HDKeyPair.fromPrivateKeyBytes(privateKey: secretKey);
  final user = await MnemonicWallet.fromMnemonic(userMnemonic);

  stdout
    ..writeln('Program ID:    ${programId.toBase58()}')
    ..writeln('Vault PDA:     ${vaultPda.toBase58()}')
    ..writeln('Sponsor:       ${sponsor.publicKey.toBase58()}')
    ..writeln('User:          ${user.address}')
    ..writeln('Destination:   $destination')
    ..writeln('Mint:          $mint')
    ..writeln('Amount:        $amount')
    ..writeln('Max fee:       $maxFeeLamports lamports')
    ..writeln('RPC:           $rpcUrl');

  final client = FeeVaultClient(
    rpcUrl: rpcUrl,
    programId: programId,
    vaultPda: vaultPda,
  );

  final signature = await client.sendGaslessSplTransfer(
    user: user,
    sponsor: sponsor,
    destination: destination,
    mint: mint,
    amount: amount,
    maxFeeLamports: maxFeeLamports,
  );

  stdout
    ..writeln('')
    ..writeln('Signature: $signature')
    ..writeln('Explorer:  https://solscan.io/tx/$signature?cluster=devnet');
}
