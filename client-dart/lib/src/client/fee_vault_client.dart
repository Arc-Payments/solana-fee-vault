import 'package:solana/dto.dart' as dto;
import 'package:solana/encoder.dart';
import 'package:solana/solana.dart';

import '../anchor/compute_budget.dart';
import '../anchor/instructions.dart';
import '../transaction/gasless_transaction_builder.dart';
import '../wallet/mnemonic_wallet.dart';

/// High-level facade that builds, signs, and submits a gasless SPL transfer
/// using the `fee_vault` program.
///
/// A single call to [sendGaslessSplTransfer] produces an atomic transaction
/// containing four instructions, in this order:
///
///   1. `top_up_sponsor(maxFeeLamports)` — moves at most `maxFeeLamports` from
///      the vault PDA to the sponsor account so the sponsor can pay the fee.
///   2. `setComputeUnitLimit` — caps compute units; required for predictable
///      priority fees.
///   3. `setComputeUnitPrice` — sets the per-unit micro-lamport priority fee.
///   4. SPL `transfer` — the user-authorized token transfer.
///
/// The sponsor is the fee payer; the user signs the SPL transfer as the source
/// account's owner. Both signatures are placed at the correct positions by
/// [GaslessTransactionBuilder].
///
/// **Limitations (intentional in v1):**
/// - The destination must already have an associated token account for the
///   mint. Creating an ATA inside the gasless transaction is possible but
///   doubles the compute budget and the rent the sponsor has to cover; that
///   path is left to the caller.
/// - This v1 does not append a `sweep_remainder` instruction. Doing so is a
///   trivial extension once the caller has accounting in place to know what
///   the sponsor's resting balance should be.
class FeeVaultClient {
  FeeVaultClient({
    required Uri rpcUrl,
    required this.programId,
    required this.vaultPda,
    Uri? websocketUrl,
    Duration timeout = const Duration(seconds: 30),
  }) : _client = SolanaClient(
          rpcUrl: rpcUrl,
          websocketUrl: websocketUrl ?? _wsFromHttp(rpcUrl),
          timeout: timeout,
        );

  /// The deployed `fee_vault` program ID.
  final Ed25519HDPublicKey programId;

  /// The PDA `[b"fee_vault"]` for the deployed `programId`. Pass it in to
  /// avoid recomputing on every call. Construct with
  /// `await FeeVaultInstructions.findVaultPda(programId)`.
  final Ed25519HDPublicKey vaultPda;

  final SolanaClient _client;

  /// The underlying [SolanaClient]. Exposed so callers can issue read-only
  /// RPC calls (balance checks, etc.) without instantiating a second client.
  SolanaClient get solanaClient => _client;

  /// Send a gasless SPL token transfer.
  ///
  /// Returns the transaction signature. The transaction is submitted with
  /// preflight at the `confirmed` commitment level; the caller can poll for
  /// confirmation using [solanaClient].
  Future<String> sendGaslessSplTransfer({
    required MnemonicWallet user,
    required Ed25519HDKeyPair sponsor,
    required String destination,
    required String mint,
    required BigInt amount,
    int maxFeeLamports = 10_000,
    int computeUnitLimit = 50_000,
    int computeUnitPriceMicroLamports = 1_000,
  }) async {
    final destinationPubkey = Ed25519HDPublicKey.fromBase58(destination);
    final mintPubkey = Ed25519HDPublicKey.fromBase58(mint);

    final sourceAta = await findAssociatedTokenAddress(
      owner: user.publicKey,
      mint: mintPubkey,
    );
    final destinationAta = await findAssociatedTokenAddress(
      owner: destinationPubkey,
      mint: mintPubkey,
    );

    final destinationAtaExists = await _accountExists(destinationAta);
    if (!destinationAtaExists) {
      throw StateError(
        'Destination $destination has no associated token account for mint $mint. '
        'Create one before calling sendGaslessSplTransfer (this client does not '
        'fund ATA creation in v1).',
      );
    }

    final instructions = <Instruction>[
      FeeVaultInstructions.topUpSponsor(
        programId: programId,
        vaultPda: vaultPda,
        authority: sponsor.publicKey,
        sponsor: sponsor.publicKey,
        maxLamports: BigInt.from(maxFeeLamports),
      ),
      ComputeBudget.setComputeUnitLimit(units: computeUnitLimit),
      ComputeBudget.setComputeUnitPrice(
        microLamports: computeUnitPriceMicroLamports,
      ),
      TokenInstruction.transfer(
        amount: amount.toInt(),
        source: sourceAta,
        destination: destinationAta,
        owner: user.publicKey,
      ),
    ];

    final blockhash = await _client.rpcClient
        .getLatestBlockhash(commitment: dto.Commitment.confirmed)
        .value;

    final signedTx = await GaslessTransactionBuilder.signAtomic(
      message: Message(instructions: instructions),
      recentBlockhash: blockhash.blockhash,
      feePayer: sponsor,
      signers: [sponsor, user.keyPair],
    );

    return _client.rpcClient.sendTransaction(
      signedTx.encode(),
      preflightCommitment: dto.Commitment.confirmed,
    );
  }

  Future<bool> _accountExists(Ed25519HDPublicKey address) async {
    final result = await _client.rpcClient.getAccountInfo(
      address.toBase58(),
      encoding: dto.Encoding.base64,
      commitment: dto.Commitment.confirmed,
    );
    return result.value != null;
  }
}

Uri _wsFromHttp(Uri http) => http.replace(
      scheme: http.scheme == 'https' ? 'wss' : 'ws',
    );
