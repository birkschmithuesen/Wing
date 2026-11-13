// Punctuation and symbols delimit prose references. Hyphens and underscores
// belong to names; a colon joins plugin and skill names. Slashes and backslashes
// keep paths and URLs literal.
const _slashNameCharacter = r'[\p{L}\p{M}\p{N}_-]';
const _slashName = '$_slashNameCharacter+(?::$_slashNameCharacter+)?';
const _slashQueryName = '(?:$_slashNameCharacter+(?::$_slashNameCharacter*)?)?';
const _slashSeparator = '(?![-_/\\\\]|:$_slashNameCharacter)[\\s\\p{P}\\p{S}]';
final _slashReferencePattern = RegExp(
  '(^|$_slashSeparator)(/$_slashName)(?=$_slashSeparator|\$)',
  unicode: true,
);
final _slashLiteralPrefixPattern = RegExp(
  '(?:^|$_slashSeparator'
  r'|[/\\])(?:\.\.?|[A-Za-z]:)$|(?:^|\s)[^\s]*://[^\s]*$',
  unicode: true,
);
final _slashQueryPattern = RegExp(
  '(^|$_slashSeparator)(/$_slashQueryName)\$',
  unicode: true,
);
final _leadingSlashQueryPattern = RegExp(
  '^/$_slashName(?:\\s[\\s\\S]*)\$',
  unicode: true,
);

bool _slashIsLiteral(String text, int start) =>
    _slashLiteralPrefixPattern.hasMatch(text.substring(0, start));

Iterable<RegExpMatch> _slashReferences(String text) => _slashReferencePattern
    .allMatches(text)
    .where((match) => !_slashIsLiteral(text, match.end - match[2]!.length));

class SlashInvocation {
  final String name;
  final String argument;
  const SlashInvocation(this.name, this.argument);

  static SlashInvocation? parse(String text) {
    final match = RegExp(
      '^/($_slashName)(?:$_slashSeparator\\s*([\\s\\S]*))?\$',
      unicode: true,
    ).firstMatch(text.trim());
    return match == null ? null : SlashInvocation(match[1]!, match[2] ?? '');
  }
}

class SlashCommand {
  final String text;
  final String description;
  final String category;
  const SlashCommand(this.text, this.description, this.category);

  bool get isSkill => category == 'Skills';
}

/// The gateway owns the catalog, including user commands, plugins and skills.
class SlashCatalog {
  final List<SlashCommand> commands;
  final Map<String, String> canonical;
  final Map<String, dynamic> metadata;
  final String warning;
  const SlashCatalog(
    this.commands,
    this.canonical,
    this.metadata,
    this.warning,
  );

  static String _withSlash(String name) =>
      name.startsWith('/') ? name : '/$name';

  factory SlashCatalog.fromJson(Map<String, dynamic> value) {
    final pairs = value['pairs'];
    if (pairs is! List) throw const FormatException('Missing command catalog');
    final categories = <String, String>{};
    for (final category in (value['categories'] as List? ?? [])) {
      for (final pair in category['pairs'] as List) {
        categories[_withSlash(pair[0] as String)] = category['name'] as String;
      }
    }
    // Hermes appends skills to pairs and supplies their identity separately;
    // they are not included in the registry's categories array.
    for (final name in (value['skills'] as Map? ?? {}).keys) {
      categories[_withSlash(name as String)] = 'Skills';
    }
    return SlashCatalog(
      pairs.map((pair) {
        if (pair is! List ||
            pair.length != 2 ||
            pair[0] is! String ||
            pair[1] is! String) {
          throw const FormatException('Invalid command catalog entry');
        }
        final name = _withSlash(pair[0]);
        return SlashCommand(name, pair[1], categories[name] ?? 'Commands');
      }).toList(),
      Map<String, String>.from(value['canon'] as Map? ?? {}).map(
        (key, value) =>
            MapEntry(_withSlash(key).toLowerCase(), _withSlash(value)),
      ),
      Map<String, dynamic>.from(value['commands'] as Map? ?? {}),
      value['warning'] as String? ?? '',
    );
  }

  String resolve(String name) =>
      (canonical['/${name.toLowerCase()}'] ?? '/$name').substring(1);

  String? unavailable(String name) {
    final entry = metadata['/$name'];
    final desktop = entry is Map ? entry['desktop'] : null;
    return switch (desktop) {
      'advanced' =>
        '/$name is not available as a chat command. Use the relevant management controls or the Hermes terminal.',
      'settings' =>
        '/$name is not available as a chat command. Use the relevant settings.',
      'terminal' => '/$name requires the Hermes terminal.',
      'messaging' =>
        '/$name is only available through a Hermes messaging integration.',
      'composer-voice' =>
        'This command records audio on the Hermes host. Phone voice control is not available in this workspace.',
      _ => null,
    };
  }

  List<SlashCommand> search(String text) {
    final query = text.replaceFirst(RegExp(r'^/'), '').toLowerCase();
    return commands
        .where(
          (c) =>
              c.text.toLowerCase().contains(query) ||
              c.description.toLowerCase().contains(query) ||
              canonical.entries.any(
                (e) => e.value == c.text && e.key.contains(query),
              ),
        )
        .toList();
  }

  /// Exact skill references at prose boundaries; paths and URLs stay literal.
  Iterable<SlashSkillReference> skillReferences(String text) =>
      SlashSkillReference.inText(
        text,
        commands.where((c) => c.isSkill).map((c) => c.text),
      );
}

class SlashSkillReference {
  const SlashSkillReference(this.text, this.start, this.end);
  final String text;
  final int start;
  final int end;

  /// Catalog reads use the same boundaries as highlighting and dispatch.
  static bool hasInlineToken(String text) =>
      _slashReferences(text).any((match) => match.end - match[2]!.length > 0);

  static Iterable<SlashSkillReference> inText(
    String text,
    Iterable<String> names,
  ) sync* {
    final skills = names.toSet();
    for (final match in _slashReferences(text)) {
      final token = match[2]!;
      if (skills.contains(token)) {
        yield SlashSkillReference(token, match.end - token.length, match.end);
      }
    }
  }
}

/// One immutable response for the exact query before the Flutter cursor.
/// Protocol offsets count Unicode code points; replacement offsets count UTF-16.
class SlashCompletion {
  SlashCompletion._(
    this.query,
    Iterable<SlashCommand> items,
    this.replaceFrom,
    this.warning,
  ) : items = List.unmodifiable(items);

  final String query;
  final List<SlashCommand> items;
  final int replaceFrom;
  final String warning;

  /// The active inline token, or the leading command and its arguments.
  static String? queryToken(String prefix) {
    // Ordinary drafts are checked while typing and during workspace updates.
    // Without a slash there cannot be a command or inline skill token.
    if (!prefix.contains('/')) return null;
    final inline = _slashQueryPattern.firstMatch(prefix);
    if (inline != null &&
        !_slashIsLiteral(prefix, inline.end - inline[2]!.length)) {
      return inline[2];
    }
    if (_leadingSlashQueryPattern.hasMatch(prefix)) {
      return prefix;
    }
    return null;
  }

  static bool isQuery(String query) => queryToken(query) != null;
  static bool usesCatalog(String query) =>
      queryToken(query) != query || !query.contains(RegExp(r'\s'));
  bool get showsNoMatches => items.isEmpty && usesCatalog(query);

  factory SlashCompletion.fromCatalog(String query, SlashCatalog catalog) {
    final token = queryToken(query);
    if (token == null) throw const FormatException('No slash query at cursor');
    final start = query.length - token.length;
    return SlashCompletion._(
      query,
      catalog.search(token).where((item) => start == 0 || item.isSkill),
      start,
      catalog.warning,
    );
  }

  factory SlashCompletion.fromJson(
    String query,
    Map<String, dynamic> value, {
    required String warning,
  }) {
    final rows = value['items'];
    final offset = value['replace_from'];
    final codePoints = query.runes;
    if (rows is! List ||
        offset is! int ||
        offset < 0 ||
        offset > codePoints.length) {
      throw const FormatException('Invalid slash completion');
    }
    final items = <SlashCommand>[];
    for (final row in rows) {
      if (row is! Map ||
          row['text'] is! String ||
          (row['meta'] != null && row['meta'] is! String)) {
        throw const FormatException('Invalid slash completion item');
      }
      items.add(
        SlashCommand(
          row['text'] as String,
          row['meta'] as String? ?? '',
          row['kind'] == 'skill' ? 'Skills' : '',
        ),
      );
    }
    return SlashCompletion._(
      query,
      items,
      String.fromCharCodes(codePoints.take(offset)).length,
      warning,
    );
  }

  /// Selection applies only to this query and an item issued by this response.
  /// Cursor extraction is rendering work; insertion and suffix rules live here.
  SlashCompletionEdit? select(
    SlashCommand item, {
    required String text,
    required int cursor,
  }) {
    if (cursor < 0 ||
        cursor > text.length ||
        text.substring(0, cursor) != query ||
        !items.any((issued) => identical(issued, item))) {
      return null;
    }
    final suffix = text.substring(cursor);
    final insertion = '${item.text}${suffix.startsWith(' ') ? '' : ' '}';
    return SlashCompletionEdit._(
      text.replaceRange(replaceFrom, cursor, insertion),
      replaceFrom + insertion.length,
    );
  }
}

class SlashCompletionEdit {
  const SlashCompletionEdit._(this.text, this.cursor);
  final String text;
  final int cursor;
}
