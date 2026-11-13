/// Validate external proof cases before any fixture or CLI selection can skip
/// them. An empty corpus or missing representative cannot certify a checker.
List<Map> validatedProofCases(
  Object? value, {
  Set<String> requiredNames = const {},
}) {
  if (value is! List || value.isEmpty) {
    throw const FormatException('Checker proof requires nonempty cases.');
  }
  final names = <String>{};
  final exits = <int>{};
  final cases = <Map>[];
  for (final entry in value) {
    if (entry is! Map) {
      throw const FormatException('Checker proof case must be an object.');
    }
    final name = entry['name'];
    final status = entry['exit'];
    if (name is! String || name.trim().isEmpty || !names.add(name)) {
      throw const FormatException(
        'Proof case names must be nonempty and unique.',
      );
    }
    if (status is! int || !const {0, 1, 2}.contains(status)) {
      throw FormatException('$name: expected exit 0, 1 or 2.');
    }
    exits.add(status);
    cases.add(entry);
  }
  final missingNames = requiredNames.difference(names);
  final missingExits = const {0, 1, 2}.difference(exits);
  if (missingNames.isNotEmpty || missingExits.isNotEmpty) {
    throw FormatException(
      'Missing CLI representatives $missingNames or exit categories $missingExits.',
    );
  }
  return cases;
}
