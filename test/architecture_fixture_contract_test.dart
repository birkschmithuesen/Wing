import 'package:flutter_test/flutter_test.dart';

import '../tools/architecture/fixture_contract.dart';

List<Map<String, Object?>> cases() => [
  {'name': 'valid', 'exit': 0, 'source': 'valid fixture'},
  {'name': 'invalid', 'exit': 1},
  {'name': 'input', 'exit': 2},
];

void main() {
  test('complete corpus retains the fixture payload', () {
    final original = cases();
    expect(validatedProofCases(original, requiredNames: {'valid'}), original);
  });

  for (final empty in [null, [], {}]) {
    test('empty corpus $empty cannot certify a checker', () {
      expect(() => validatedProofCases(empty), throwsFormatException);
    });
  }

  for (final status in [0, 1, 2]) {
    test('exit category $status cannot silently disappear', () {
      final remaining = cases()
        ..removeWhere((entry) => entry['exit'] == status);
      expect(() => validatedProofCases(remaining), throwsFormatException);
    });
  }

  test('required CLI representative cannot silently disappear', () {
    expect(
      () => validatedProofCases(cases(), requiredNames: {'missing'}),
      throwsFormatException,
    );
  });

  for (final name in ['', ' ', null, 'invalid']) {
    test('case name $name must be nonempty and unique', () {
      final invalid = cases()..first['name'] = name;
      expect(() => validatedProofCases(invalid), throwsFormatException);
    });
  }

  for (final status in [false, '1', null, 3]) {
    test('unsupported exit $status is rejected', () {
      final invalid = cases()..first['exit'] = status;
      expect(() => validatedProofCases(invalid), throwsFormatException);
    });
  }
}
