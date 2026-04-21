import 'dart:convert';

import 'package:crypto/crypto.dart';

/// Compute the 8-byte instruction or account discriminator that Anchor prepends
/// to every instruction's data payload (and uses as the prefix on every account
/// it owns).
///
/// Anchor's convention is `sha256("<namespace>:<name>")[..8]`. For the
/// instruction `top_up_sponsor`, the namespace is `global` and the resulting
/// preimage is `global:top_up_sponsor`. For an account discriminator the
/// namespace is `account` and the name is the PascalCase struct name, e.g.
/// `account:FeeVault`.
///
/// This matches the implementation in `anchor-syn` (Rust) and `@coral-xyz/anchor`
/// (TypeScript).
List<int> anchorDiscriminator(String name, {String namespace = 'global'}) {
  final preimage = utf8.encode('$namespace:$name');
  return sha256.convert(preimage).bytes.sublist(0, 8);
}

/// Convenience for an instruction discriminator (`global:<name>`).
List<int> anchorInstructionDiscriminator(String instructionName) =>
    anchorDiscriminator(instructionName);

/// Convenience for an account discriminator (`account:<PascalCaseName>`).
List<int> anchorAccountDiscriminator(String accountName) =>
    anchorDiscriminator(accountName, namespace: 'account');
