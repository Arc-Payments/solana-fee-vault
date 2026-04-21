import 'package:bip39/bip39.dart' as bip39;
import 'package:fee_vault_client/fee_vault_client.dart';
import 'package:test/test.dart';

void main() {
  group('MnemonicWallet.generateMnemonic', () {
    test('produces a 12-word mnemonic at 128-bit strength (default)', () {
      final m = MnemonicWallet.generateMnemonic();
      expect(m.split(' ').length, 12);
      expect(bip39.validateMnemonic(m), true);
    });

    test('produces a 24-word mnemonic at 256-bit strength', () {
      final m = MnemonicWallet.generateMnemonic(strength: 256);
      expect(m.split(' ').length, 24);
      expect(bip39.validateMnemonic(m), true);
    });

    test('rejects unsupported strengths', () {
      expect(() => MnemonicWallet.generateMnemonic(strength: 192),
          throwsArgumentError);
      expect(() => MnemonicWallet.generateMnemonic(strength: 0),
          throwsArgumentError);
    });

    test('subsequent calls yield distinct mnemonics', () {
      final a = MnemonicWallet.generateMnemonic();
      final b = MnemonicWallet.generateMnemonic();
      expect(a, isNot(b));
    });
  });

  group('MnemonicWallet.isValid', () {
    test('accepts the canonical BIP39 zero-vector', () {
      expect(
        MnemonicWallet.isValid(
          'abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about',
        ),
        true,
      );
    });

    test('rejects a mnemonic with a bad checksum', () {
      expect(
        MnemonicWallet.isValid(
          'abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon',
        ),
        false,
      );
    });

    test('normalizes whitespace before validating', () {
      expect(
        MnemonicWallet.isValid(
          '  abandon  abandon abandon abandon  abandon abandon abandon abandon abandon abandon abandon about ',
        ),
        true,
      );
    });
  });

  group('MnemonicWallet.fromMnemonic', () {
    // Test vector: BIP39 zero-vector "abandon...about" derived at the default
    // Solana path m/44'/501'/0'/0' must produce this address.
    // Verified independently via `Ed25519HDKeyPair.fromMnemonic`.
    const expectedAddress = 'D2PPQSYFe83nDzk96FqGumVU8JA7J8vj2Rhjc2oXzEi5';
    const goodMnemonic =
        'abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about';

    test('derives the canonical address for the zero-vector mnemonic',
        () async {
      final w = await MnemonicWallet.fromMnemonic(goodMnemonic);
      expect(w.address, expectedAddress);
      expect(w.publicKey.toBase58(), expectedAddress);
    });

    test('messy whitespace produces the same address as the clean form',
        () async {
      final messy =
          '  abandon  abandon abandon abandon  abandon abandon abandon abandon abandon abandon abandon about ';
      final w1 = await MnemonicWallet.fromMnemonic(goodMnemonic);
      final w2 = await MnemonicWallet.fromMnemonic(messy);
      expect(w1.address, w2.address);
    });

    test('rejects an invalid mnemonic', () async {
      await expectLater(
        MnemonicWallet.fromMnemonic('not actually a mnemonic at all'),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('round-trips a freshly-generated mnemonic', () async {
      final m = MnemonicWallet.generateMnemonic(strength: 256);
      final w = await MnemonicWallet.fromMnemonic(m);
      expect(w.address, isNotEmpty);
      expect(w.keyPair.publicKey.bytes.length, 32);
    });
  });
}
