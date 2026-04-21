import 'dart:convert';

import 'package:fee_vault_client/fee_vault_client.dart';
import 'package:solana/encoder.dart';
import 'package:solana/solana.dart';
import 'package:test/test.dart';

const _systemProgramId = '11111111111111111111111111111111';

void main() {
  // A handful of throwaway pubkeys we can use in pure-syntactic tests.
  final programId = Ed25519HDPublicKey.fromBase58(
    '4fjNH5DfvXbfNv45DevfweY2D5sLzgdWCQ1MK6zY9HR8',
  );
  final vaultPda = Ed25519HDPublicKey.fromBase58(
    'GYST74DEsDk2qAEo3bw4KFp6kF3H6obYM1KwJYbtWfRD',
  );
  final authority = Ed25519HDPublicKey.fromBase58(
    '7GAEGafU7dZzxcGLiQD3Mfa5rs8kM1NSihFftnfbw1Wr',
  );
  final emergencyAuthority = Ed25519HDPublicKey.fromBase58(
    'BPF7HLW1bm6cMzpc8aVRgNtKkqkuaXtKvSpKHxXM6e9F',
  );
  final payer = Ed25519HDPublicKey.fromBase58(
    'D2PPQSYFe83nDzk96FqGumVU8JA7J8vj2Rhjc2oXzEi5',
  );
  final sponsor = authority; // sponsor = authority is the gasless layout.

  group('FeeVaultInstructions.initialize', () {
    final ix = FeeVaultInstructions.initialize(
      programId: programId,
      vaultPda: vaultPda,
      authority: authority,
      emergencyAuthority: emergencyAuthority,
      payer: payer,
      maxDailySpend: BigInt.from(500_000_000),
      maxPerTransaction: BigInt.from(10_000_000),
    );

    test('uses the program ID', () {
      expect(ix.programId, programId);
    });

    test('account meta order matches the Rust Initialize struct', () {
      // [vault, authority, emergency_authority, payer, system_program]
      expect(ix.accounts.length, 5);

      expect(ix.accounts[0].pubKey, vaultPda);
      expect(ix.accounts[0].isWriteable, true);
      expect(ix.accounts[0].isSigner, false);

      expect(ix.accounts[1].pubKey, authority);
      expect(ix.accounts[1].isWriteable, false);
      expect(ix.accounts[1].isSigner, true);

      expect(ix.accounts[2].pubKey, emergencyAuthority);
      expect(ix.accounts[2].isWriteable, false);
      expect(ix.accounts[2].isSigner, false);

      expect(ix.accounts[3].pubKey, payer);
      expect(ix.accounts[3].isWriteable, true);
      expect(ix.accounts[3].isSigner, true);

      expect(ix.accounts[4].pubKey.toBase58(), _systemProgramId);
      expect(ix.accounts[4].isWriteable, false);
      expect(ix.accounts[4].isSigner, false);
    });

    test('data layout is [discriminator(8) || u64 daily || u64 per_tx]', () {
      final bytes = ix.data.toList();
      expect(bytes.length, 8 + 8 + 8);
      expect(bytes.sublist(0, 8), anchorInstructionDiscriminator('initialize'));
      // 500_000_000 little-endian u64
      expect(bytes.sublist(8, 16), [0x00, 0x65, 0xcd, 0x1d, 0, 0, 0, 0]);
      // 10_000_000 little-endian u64
      expect(bytes.sublist(16, 24), [0x80, 0x96, 0x98, 0x00, 0, 0, 0, 0]);
    });
  });

  group('FeeVaultInstructions.topUpSponsor', () {
    final ix = FeeVaultInstructions.topUpSponsor(
      programId: programId,
      vaultPda: vaultPda,
      authority: authority,
      sponsor: sponsor,
      maxLamports: BigInt.from(10_000),
    );

    test('account meta order matches the Rust TopUpSponsor struct', () {
      // [vault, authority, sponsor, system_program]
      expect(ix.accounts.length, 4);

      expect(ix.accounts[0].pubKey, vaultPda);
      expect(ix.accounts[0].isWriteable, true);
      expect(ix.accounts[0].isSigner, false);

      expect(ix.accounts[1].pubKey, authority);
      expect(ix.accounts[1].isWriteable, false);
      expect(ix.accounts[1].isSigner, true);

      expect(ix.accounts[2].pubKey, sponsor);
      expect(ix.accounts[2].isWriteable, true);
      expect(ix.accounts[2].isSigner, false);

      expect(ix.accounts[3].pubKey.toBase58(), _systemProgramId);
      expect(ix.accounts[3].isWriteable, false);
      expect(ix.accounts[3].isSigner, false);
    });

    test('data layout is [discriminator(8) || u64 max_lamports]', () {
      final bytes = ix.data.toList();
      expect(bytes.length, 8 + 8);
      expect(bytes.sublist(0, 8),
          anchorInstructionDiscriminator('top_up_sponsor'));
      // 10_000 = 0x2710 little-endian u64
      expect(bytes.sublist(8, 16), [0x10, 0x27, 0, 0, 0, 0, 0, 0]);
    });

    test('rejects max_lamports above u64::MAX', () {
      expect(
        () => FeeVaultInstructions.topUpSponsor(
          programId: programId,
          vaultPda: vaultPda,
          authority: authority,
          sponsor: sponsor,
          maxLamports: BigInt.parse('18446744073709551616'), // 2^64
        ),
        throwsArgumentError,
      );
    });

    test('rejects negative max_lamports', () {
      expect(
        () => FeeVaultInstructions.topUpSponsor(
          programId: programId,
          vaultPda: vaultPda,
          authority: authority,
          sponsor: sponsor,
          maxLamports: BigInt.from(-1),
        ),
        throwsArgumentError,
      );
    });
  });

  group('FeeVaultInstructions.sweepRemainder', () {
    final ix = FeeVaultInstructions.sweepRemainder(
      programId: programId,
      vaultPda: vaultPda,
      authority: authority,
      sponsor: sponsor,
    );

    test('account meta order matches the Rust SweepRemainder struct', () {
      // [vault, authority, sponsor (mut+signer), system_program]
      expect(ix.accounts.length, 4);

      expect(ix.accounts[0].pubKey, vaultPda);
      expect(ix.accounts[0].isWriteable, true);
      expect(ix.accounts[0].isSigner, false);

      expect(ix.accounts[1].pubKey, authority);
      expect(ix.accounts[1].isWriteable, false);
      expect(ix.accounts[1].isSigner, true);

      expect(ix.accounts[2].pubKey, sponsor);
      expect(ix.accounts[2].isWriteable, true);
      expect(ix.accounts[2].isSigner, true);

      expect(ix.accounts[3].pubKey.toBase58(), _systemProgramId);
      expect(ix.accounts[3].isWriteable, false);
      expect(ix.accounts[3].isSigner, false);
    });

    test('data is exactly the 8-byte discriminator (no args)', () {
      final bytes = ix.data.toList();
      expect(bytes.length, 8);
      expect(bytes, anchorInstructionDiscriminator('sweep_remainder'));
    });
  });

  group('PDA derivation', () {
    test('seed kFeeVaultSeed is the literal "fee_vault"', () {
      expect(utf8.decode(kFeeVaultSeed), 'fee_vault');
    });

    test('findVaultPda is deterministic for a given program ID', () async {
      final a = await FeeVaultInstructions.findVaultPda(programId);
      final b = await FeeVaultInstructions.findVaultPda(programId);
      expect(a, b);
    });

    test('findVaultPda differs for different program IDs', () async {
      final altProgramId = Ed25519HDPublicKey.fromBase58(
        '11111111111111111111111111111111',
      );
      final p1 = await FeeVaultInstructions.findVaultPda(programId);
      final p2 = await FeeVaultInstructions.findVaultPda(altProgramId);
      expect(p1, isNot(p2));
    });
  });

  group('AccountMeta basics', () {
    test('writeable factory yields isWriteable=true', () {
      final meta = AccountMeta.writeable(pubKey: vaultPda, isSigner: false);
      expect(meta.isWriteable, true);
      expect(meta.isSigner, false);
    });

    test('readonly factory yields isWriteable=false', () {
      final meta = AccountMeta.readonly(pubKey: vaultPda, isSigner: true);
      expect(meta.isWriteable, false);
      expect(meta.isSigner, true);
    });
  });
}
