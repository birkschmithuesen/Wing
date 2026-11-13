/// A canonical stock fallback route. Opaque routing fields belong to this
/// entry and survive edits; presenters receive only provider/model identity.
class FallbackModel {
  FallbackModel.fromWire(Map value) : _fields = _freezeMap(value) {
    if (_fields['provider'] is! String ||
        (_fields['provider'] as String).trim().isEmpty ||
        _fields['model'] is! String ||
        (_fields['model'] as String).trim().isEmpty) {
      throw const FormatException('Invalid stock fallback route');
    }
  }

  final Map<String, Object?> _fields;
  String get provider => _fields['provider'] as String;
  String get model => _fields['model'] as String;
  Map<String, Object?> toWire() => _fields;

  FallbackModel withSelection(String provider, String model) =>
      FallbackModel.fromWire({
        ..._fields,
        'provider': provider,
        'model': model,
      });

  static Map<String, Object?> _freezeMap(Map value) {
    final result = <String, Object?>{};
    for (final entry in value.entries) {
      if (entry.key is! String) {
        throw const FormatException('Invalid fallback routing field');
      }
      result[entry.key as String] = _freeze(entry.value);
    }
    return Map.unmodifiable(result);
  }

  static Object? _freeze(Object? value) => switch (value) {
    Map value => _freezeMap(value),
    List value => List<Object?>.unmodifiable(value.map(_freeze)),
    null || String() || bool() || num() => value,
    _ => throw const FormatException('Invalid fallback routing value'),
  };

  static List<FallbackModel> fromConfig(Map<String, dynamic> config) {
    final value = config.containsKey('fallback_providers')
        ? config['fallback_providers']
        : const [];
    if (value is! List || value.any((row) => row is! Map)) {
      throw const FormatException('Expected canonical fallback objects');
    }
    return List.unmodifiable(
      value.map((row) => FallbackModel.fromWire(row as Map)),
    );
  }
}
