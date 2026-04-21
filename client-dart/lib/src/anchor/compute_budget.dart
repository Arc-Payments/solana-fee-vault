import 'package:solana/solana.dart' show ComputeBudgetInstruction;

/// Wrappers around the `solana` package's `ComputeBudgetInstruction` factories
/// with names that match the upstream Solana SDK conventions.
///
/// Setting an explicit compute unit limit is required if you want priority-fee
/// pricing to take effect, because the runtime defaults the price multiplier to
/// the maximum unit budget for the transaction otherwise.
///
/// Reasonable defaults for an SPL transfer:
/// - `units`: 50_000 for a single transfer to an existing ATA, 200_000 if you
///   also need to create the destination ATA in the same transaction.
/// - `microLamports`: 1_000 (one micro-lamport per CU) is a common floor.
class ComputeBudget {
  const ComputeBudget._();

  /// Cap the compute units the transaction may consume.
  static ComputeBudgetInstruction setComputeUnitLimit({required int units}) =>
      ComputeBudgetInstruction.setComputeUnitLimit(units: units);

  /// Set the priority-fee per compute unit, in micro-lamports.
  static ComputeBudgetInstruction setComputeUnitPrice({
    required int microLamports,
  }) =>
      ComputeBudgetInstruction.setComputeUnitPrice(
          microLamports: microLamports);
}
