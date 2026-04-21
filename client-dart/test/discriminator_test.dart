import 'package:fee_vault_client/fee_vault_client.dart';
import 'package:test/test.dart';

void main() {
  group('anchorInstructionDiscriminator', () {
    // Reference vectors computed with `sha256("global:<name>")[..8]`,
    // which is what `@coral-xyz/anchor` and the Anchor Rust macros use.
    // To regenerate:
    //   node -e "console.log(require('crypto').createHash('sha256').update('global:initialize').digest('hex').substring(0,16))"
    const cases = <String, List<int>>{
      'initialize': [0xaf, 0xaf, 0x6d, 0x1f, 0x0d, 0x98, 0x9b, 0xed],
      'top_up_sponsor': [0x68, 0x21, 0x23, 0x57, 0xc8, 0x0f, 0xc2, 0xbe],
      'sweep_remainder': [0x9e, 0xe2, 0x3c, 0xe1, 0x14, 0xc4, 0x6f, 0x9c],
      'emergency_pause': [0x15, 0x8f, 0x1b, 0x8e, 0xc8, 0xb5, 0xd2, 0xff],
      'resume_operations': [0xf0, 0x8d, 0x85, 0x9a, 0xe8, 0x0f, 0xa6, 0x9d],
      'update_limits': [0x59, 0x25, 0x89, 0x3c, 0x4b, 0x46, 0x30, 0xc2],
    };

    cases.forEach((name, expected) {
      test('matches Anchor for "$name"', () {
        expect(anchorInstructionDiscriminator(name), expected);
      });
    });

    test('returns exactly 8 bytes', () {
      expect(anchorInstructionDiscriminator('initialize').length, 8);
      expect(anchorInstructionDiscriminator('').length, 8);
      expect(
        anchorInstructionDiscriminator(
                'a_very_long_instruction_name_that_exceeds_normal_length')
            .length,
        8,
      );
    });

    test('namespace defaults to "global"', () {
      expect(
        anchorDiscriminator('initialize'),
        anchorInstructionDiscriminator('initialize'),
      );
    });
  });

  group('anchorAccountDiscriminator', () {
    test('uses the "account" namespace', () {
      // sha256("account:FeeVault")[..8]
      expect(
        anchorAccountDiscriminator('FeeVault'),
        const [0xc0, 0xb2, 0x45, 0xe8, 0x3a, 0x95, 0x9d, 0x84],
      );
    });

    test('produces a different value than the instruction with the same name',
        () {
      expect(
        anchorAccountDiscriminator('FeeVault'),
        isNot(anchorInstructionDiscriminator('FeeVault')),
      );
    });
  });
}
