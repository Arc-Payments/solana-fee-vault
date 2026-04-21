import 'dart:isolate';

import 'package:bip39/bip39.dart' as bip39;
import 'package:solana/solana.dart' show Ed25519HDKeyPair, Ed25519HDPublicKey;

/// A BIP39-mnemonic-backed Solana wallet.
///
/// `MnemonicWallet` is a thin, pure-Dart wrapper around the
/// `solana` package's [Ed25519HDKeyPair]. It exists so the mnemonic is
/// validated off the calling isolate (validation is CPU-bound and would
/// otherwise jank UI threads on mobile clients) and so consumers have a
/// stable, narrowly-typed entry point.
///
/// The derivation path is fixed at `m/44'/501'/0'/0'`, which matches what
/// `solana-keygen` produces for the default account/change pair.
class MnemonicWallet {
  const MnemonicWallet._(this.keyPair);

  /// The underlying ed25519 keypair. Use this when interacting with the
  /// `solana` package directly (signing, sending, etc.).
  final Ed25519HDKeyPair keyPair;

  /// Base58-encoded public key, suitable for showing in UIs and using as a
  /// destination address.
  String get address => keyPair.publicKey.toBase58();

  /// The 32-byte ed25519 public key as an `Ed25519HDPublicKey`.
  Ed25519HDPublicKey get publicKey => keyPair.publicKey;

  /// Derive a wallet from an existing BIP39 mnemonic.
  ///
  /// The mnemonic is normalized (whitespace collapsed) and validated on a
  /// background isolate. Throws [ArgumentError] if the mnemonic checksum is
  /// invalid.
  static Future<MnemonicWallet> fromMnemonic(String mnemonic) async {
    final normalized = await Isolate.run<String>(
      () => _validateMnemonicSync(mnemonic),
    );
    final keyPair = await Ed25519HDKeyPair.fromMnemonic(normalized);
    return MnemonicWallet._(keyPair);
  }

  /// Generate a fresh mnemonic with the given entropy strength.
  ///
  /// `strength` must be 128 (12 words) or 256 (24 words). Defaults to 128.
  static String generateMnemonic({int strength = 128}) {
    if (strength != 128 && strength != 256) {
      throw ArgumentError.value(
        strength,
        'strength',
        'must be 128 (12 words) or 256 (24 words)',
      );
    }
    return bip39.generateMnemonic(strength: strength);
  }

  /// Validate a mnemonic checksum without deriving keys. Returns `true` if the
  /// mnemonic parses cleanly and the checksum matches.
  static bool isValid(String mnemonic) {
    final normalized = _normalize(mnemonic);
    return bip39.validateMnemonic(normalized);
  }
}

String _validateMnemonicSync(String mnemonic) {
  final normalized = _normalize(mnemonic);
  if (!bip39.validateMnemonic(normalized)) {
    throw ArgumentError.value(mnemonic, 'mnemonic', 'invalid BIP39 mnemonic');
  }
  return normalized;
}

String _normalize(String mnemonic) =>
    mnemonic.trim().split(RegExp(r'\s+')).join(' ');
