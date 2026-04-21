/// Public API for the `fee_vault_client` package.
///
/// Most consumers only need the high-level [FeeVaultClient]. The lower-level
/// helpers are exported so they can be reused outside the gasless flow.
library fee_vault_client;

export 'src/wallet/mnemonic_wallet.dart';
export 'src/anchor/discriminator.dart';
export 'src/anchor/instructions.dart';
export 'src/anchor/compute_budget.dart';
export 'src/transaction/gasless_transaction_builder.dart';
export 'src/client/fee_vault_client.dart';
