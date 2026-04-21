import 'dart:typed_data';

import 'package:solana/encoder.dart';
import 'package:solana/solana.dart' show Ed25519HDKeyPair, Ed25519HDPublicKey;

/// Assembles and signs a transaction in which the **sponsor pays the fee** but
/// some of the inner instructions are signed by a **different** key (the user).
///
/// The Solana transaction format places signatures at fixed positions in the
/// header: the first signature is the fee payer's, then the remaining required
/// signatures appear in the order their pubkeys appear in `accountKeys`. To get
/// that right when more than one party signs, you have to:
///
/// 1. Compile the message with the sponsor as the fee payer so the runtime
///    knows where each pubkey lives.
/// 2. Hand each signer the **exact same** message bytes to sign.
/// 3. Look up each signer's pubkey in `compiledMessage.accountKeys` and place
///    its signature at the matching index in the final array.
///
/// Skipping step 3 (or using `Ed25519HDKeyPair.signMessage`, which assumes a
/// single signer == fee payer) produces a transaction the runtime rejects with
/// a `MissingSignatureForFee` or signature-mismatch error.
class GaslessTransactionBuilder {
  const GaslessTransactionBuilder._();

  /// Builds and signs a [SignedTx] from `message`.
  ///
  /// `feePayer` is **always** the first signer in `signers` if you want the
  /// usual gasless layout (sponsor pays). All `signers` must correspond to
  /// pubkeys present somewhere in the message's instructions, otherwise the
  /// returned transaction will be rejected as missing signatures.
  static Future<SignedTx> signAtomic({
    required Message message,
    required String recentBlockhash,
    required Ed25519HDKeyPair feePayer,
    required List<Ed25519HDKeyPair> signers,
  }) async {
    if (signers.isEmpty) {
      throw ArgumentError.value(
        signers,
        'signers',
        'must include at least the fee payer',
      );
    }

    final compiledMessage = message.compile(
      recentBlockhash: recentBlockhash,
      feePayer: feePayer.publicKey,
    );
    final messageBytes =
        Uint8List.fromList(compiledMessage.toByteArray().toList());

    // Index signers by base58 pubkey for O(1) lookup; we'll walk
    // accountKeys[0..numRequiredSignatures] and place each one in order.
    final byPubkey = <String, Ed25519HDKeyPair>{
      for (final s in signers) s.publicKey.toBase58(): s,
    };
    if (!byPubkey.containsKey(feePayer.publicKey.toBase58())) {
      throw ArgumentError.value(
        feePayer.publicKey.toBase58(),
        'feePayer',
        'feePayer must also be present in signers',
      );
    }

    final header = compiledMessage.toByteArray().take(3).toList();
    final numRequiredSignatures = header[0];
    final accountKeys = compiledMessage.map(
      legacy: (m) => m.accountKeys,
      v0: (m) => m.accountKeys,
    );

    if (accountKeys.length < numRequiredSignatures) {
      throw StateError(
        'Compiled message claims $numRequiredSignatures signatures '
        'but has only ${accountKeys.length} account keys.',
      );
    }

    final signatures = <Signature>[];
    for (var i = 0; i < numRequiredSignatures; i++) {
      final pubkeyBase58 = accountKeys[i].toBase58();
      final signer = byPubkey[pubkeyBase58];
      if (signer == null) {
        throw StateError(
          'Required signer at position $i ($pubkeyBase58) was not provided.',
        );
      }
      signatures.add(await signer.sign(messageBytes));
    }

    return SignedTx(signatures: signatures, compiledMessage: compiledMessage);
  }

  /// Convenience that resolves the latest blockhash on the calling code's
  /// behalf is intentionally not provided here; this layer is pure and easy to
  /// unit-test. See [FeeVaultClient] for a higher-level facade that fetches the
  /// blockhash and submits the transaction.
  static Ed25519HDPublicKey feePayerOf(SignedTx tx) =>
      tx.compiledMessage.accountKeys.first;
}
