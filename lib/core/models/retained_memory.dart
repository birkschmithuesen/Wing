/// The two current stock memory sources. They are not filesystem aliases.
enum RetainedMemorySource {
  memory,
  profile;

  static RetainedMemorySource fromWire(Object? value) => switch (value) {
    'memory' => RetainedMemorySource.memory,
    'profile' => RetainedMemorySource.profile,
    _ => throw const FormatException('Invalid retained memory source'),
  };
}

final _fingerprint = RegExp(r'^[0-9a-f]{12}$');

/// Exact supplied graph identity, including the current stock text fingerprint.
/// Positional IDs without a fingerprint never cross this client interface.
class RetainedMemoryIdentity {
  RetainedMemoryIdentity._(
    this.value,
    this.source,
    this.ordinal,
    this.fingerprint,
  );
  final String value, fingerprint;
  final RetainedMemorySource source;
  final int ordinal;
  factory RetainedMemoryIdentity.fromWire(Object? value) {
    if (value is! String) {
      throw const FormatException('Invalid retained memory identity');
    }
    final parts = value.split(':');
    if (parts.length != 4 ||
        parts.first != 'memory' ||
        !_fingerprint.hasMatch(parts[3])) {
      throw const FormatException('Invalid current retained memory identity');
    }
    final source = RetainedMemorySource.fromWire(parts[1]);
    final ordinal = int.tryParse(parts[2]);
    if (ordinal == null || ordinal < 0 || ordinal.toString() != parts[2]) {
      throw const FormatException('Invalid retained memory ordinal');
    }
    return RetainedMemoryIdentity._(value, source, ordinal, parts[3]);
  }
}

class RetainedMemoryCard {
  const RetainedMemoryCard._(this.identity, this.title, this.preview);
  final RetainedMemoryIdentity identity;
  final String title, preview;
  RetainedMemorySource get source => identity.source;
  bool matches(String query) =>
      '$title $preview'.toLowerCase().contains(query.toLowerCase());
}

/// Only memory cards/nodes are retained. Skill topology and unrelated graph
/// metadata do not enter the reading projection.
class RetainedMemoryGraph {
  RetainedMemoryGraph._(Iterable<RetainedMemoryCard> cards)
    : cards = List.unmodifiable(cards);
  final List<RetainedMemoryCard> cards;
  factory RetainedMemoryGraph.fromResponse(Map<String, dynamic> data) {
    final rows = data['memory'], nodes = data['nodes'];
    if (rows is! List || nodes is! List || nodes.any((n) => n is! Map)) {
      throw const FormatException('Invalid retained memory graph');
    }
    final memoryNodes =
        <int, ({RetainedMemoryIdentity identity, String title})>{};
    final identities = <String>{};
    for (final node in nodes.where((n) => n['kind'] == 'memory')) {
      final identity = RetainedMemoryIdentity.fromWire(node['id']);
      if (node['label'] is! String ||
          node['memorySource'] != identity.source.name ||
          !identities.add(identity.value) ||
          memoryNodes.containsKey(identity.ordinal)) {
        throw const FormatException('Ambiguous retained memory graph identity');
      }
      memoryNodes[identity.ordinal] = (
        identity: identity,
        title: node['label'] as String,
      );
    }
    if (memoryNodes.length != rows.length) {
      throw const FormatException('Missing retained memory graph identity');
    }
    final cards = <RetainedMemoryCard>[];
    for (final (ordinal, row) in rows.indexed) {
      if (row is! Map ||
          row['title'] is! String ||
          row['body'] is! String ||
          row['fingerprint'] is! String ||
          !_fingerprint.hasMatch(row['fingerprint'] as String)) {
        throw const FormatException('Invalid retained memory card');
      }
      final source = RetainedMemorySource.fromWire(row['source']);
      final node = memoryNodes[ordinal];
      if (node == null ||
          node.identity.source != source ||
          node.identity.fingerprint != row['fingerprint'] ||
          node.title != row['title']) {
        throw const FormatException(
          'Retained memory card does not match supplied graph node',
        );
      }
      cards.add(
        RetainedMemoryCard._(
          node.identity,
          row['title'] as String,
          row['body'] as String,
        ),
      );
    }
    return RetainedMemoryGraph._(cards);
  }
}

class RetainedMemoryDetail {
  const RetainedMemoryDetail._(this.identity, this.content);
  final RetainedMemoryIdentity identity;
  final String content;
  factory RetainedMemoryDetail.fromResponse(
    RetainedMemoryIdentity identity,
    Map<String, dynamic> data,
  ) {
    if (data['ok'] != true ||
        data['kind'] != 'memory' ||
        data['id'] != identity.value ||
        data['label'] is! String ||
        data['content'] is! String) {
      throw const FormatException('Invalid retained memory detail or identity');
    }
    return RetainedMemoryDetail._(identity, data['content'] as String);
  }
}
