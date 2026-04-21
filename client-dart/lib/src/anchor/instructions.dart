import 'dart:convert';

import 'package:solana/encoder.dart';
import 'package:solana/solana.dart' show Ed25519HDPublicKey, SystemProgram;

import 'discriminator.dart';

/// PDA seed for the singleton fee vault account.
const List<int> kFeeVaultSeed = <int>[
  102,
  101,
  101,
  95,
  118,
  97,
  117,
  108,
  116
];

/// Instruction builders for the `fee_vault` program.
///
/// Each builder produces a [Instruction] whose account-meta order matches the
/// program's `#[derive(Accounts)]` struct one-for-one, and whose data payload
/// is `discriminator (8 bytes) || borsh(args)`. Borsh's wire format for the
/// `u64` arguments used here is just little-endian; no struct framing is added.
///
/// See the on-chain program for the canonical account ordering. If you change
/// either side, change both.
class FeeVaultInstructions {
  const FeeVaultInstructions._();

  /// `initialize(max_daily_spend: u64, max_per_transaction: u64)`
  ///
  /// Account order matches the `Initialize` struct:
  /// `[vault, authority, emergency_authority, payer, system_program]`.
  ///
  /// `vault` is the PDA derived from `[b"fee_vault"]` and the program ID. It is
  /// created by this instruction; the Anchor runtime will allocate space and
  /// charge rent to `payer`.
  static Instruction initialize({
    required Ed25519HDPublicKey programId,
    required Ed25519HDPublicKey vaultPda,
    required Ed25519HDPublicKey authority,
    required Ed25519HDPublicKey emergencyAuthority,
    required Ed25519HDPublicKey payer,
    required BigInt maxDailySpend,
    required BigInt maxPerTransaction,
  }) {
    final data = ByteArray.merge([
      ByteArray(anchorInstructionDiscriminator('initialize')),
      _u64(maxDailySpend),
      _u64(maxPerTransaction),
    ]);

    return Instruction(
      programId: programId,
      accounts: [
        AccountMeta.writeable(pubKey: vaultPda, isSigner: false),
        AccountMeta.readonly(pubKey: authority, isSigner: true),
        AccountMeta.readonly(pubKey: emergencyAuthority, isSigner: false),
        AccountMeta.writeable(pubKey: payer, isSigner: true),
        AccountMeta.readonly(pubKey: SystemProgram.id, isSigner: false),
      ],
      data: data,
    );
  }

  /// `top_up_sponsor(max_lamports: u64)`
  ///
  /// Account order matches the `TopUpSponsor` struct:
  /// `[vault, authority, sponsor, system_program]`.
  ///
  /// The `authority` must be the same key recorded on the vault during
  /// `initialize`; the on-chain `has_one = authority` constraint will reject
  /// any other signer.
  static Instruction topUpSponsor({
    required Ed25519HDPublicKey programId,
    required Ed25519HDPublicKey vaultPda,
    required Ed25519HDPublicKey authority,
    required Ed25519HDPublicKey sponsor,
    required BigInt maxLamports,
  }) {
    final data = ByteArray.merge([
      ByteArray(anchorInstructionDiscriminator('top_up_sponsor')),
      _u64(maxLamports),
    ]);

    return Instruction(
      programId: programId,
      accounts: [
        AccountMeta.writeable(pubKey: vaultPda, isSigner: false),
        AccountMeta.readonly(pubKey: authority, isSigner: true),
        AccountMeta.writeable(pubKey: sponsor, isSigner: false),
        AccountMeta.readonly(pubKey: SystemProgram.id, isSigner: false),
      ],
      data: data,
    );
  }

  /// `sweep_remainder()`
  ///
  /// Account order matches the `SweepRemainder` struct:
  /// `[vault, authority, sponsor, system_program]`. Same authority check as
  /// [topUpSponsor]. The instruction is a no-op when the sponsor balance is
  /// already at or below the on-chain `MIN_SPONSOR_BALANCE` floor.
  static Instruction sweepRemainder({
    required Ed25519HDPublicKey programId,
    required Ed25519HDPublicKey vaultPda,
    required Ed25519HDPublicKey authority,
    required Ed25519HDPublicKey sponsor,
  }) {
    final data = ByteArray(anchorInstructionDiscriminator('sweep_remainder'));

    return Instruction(
      programId: programId,
      accounts: [
        AccountMeta.writeable(pubKey: vaultPda, isSigner: false),
        AccountMeta.readonly(pubKey: authority, isSigner: true),
        AccountMeta.writeable(pubKey: sponsor, isSigner: false),
        AccountMeta.readonly(pubKey: SystemProgram.id, isSigner: false),
      ],
      data: data,
    );
  }

  /// Derive the canonical `fee_vault` PDA for a given program ID.
  ///
  /// Uses the seed `b"fee_vault"`, matching the Rust program. The bump is not
  /// returned because the on-chain account stores it; clients that need it
  /// should read `FeeVault.bump` from the deserialized account once.
  static Future<Ed25519HDPublicKey> findVaultPda(
    Ed25519HDPublicKey programId,
  ) =>
      Ed25519HDPublicKey.findProgramAddress(
        seeds: const [kFeeVaultSeed],
        programId: programId,
      );
}

/// Returns true if `kFeeVaultSeed` decodes to the literal string "fee_vault".
/// Exposed for tests; not part of the runtime API.
bool $debugFeeVaultSeedMatches() => utf8.decode(kFeeVaultSeed) == 'fee_vault';

ByteArray _u64(BigInt value) {
  if (value.isNegative || value.bitLength > 64) {
    throw ArgumentError.value(value, 'value', 'must fit in u64');
  }
  return ByteArray.u64(value.toInt());
}
