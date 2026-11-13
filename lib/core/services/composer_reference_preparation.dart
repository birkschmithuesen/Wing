import '../models/server_reference.dart';
import 'dart:convert';

import '../models/composer_reference.dart';
import 'composer_reference_repository.dart';

/// One dispatch-time workflow for every ordinary-chat send surface. It never
/// owns a draft, runtime or RPC submission, and cannot partially accept context.
final class ComposerReferencePreparation {
  const ComposerReferencePreparation(this.repository);
  final ComposerReferenceRepository repository;
  static const maxFileBytes = 4 * 1024 * 1024;
  static const maxReferences = 16;

  Future<MentionCompletion> complete(
    MentionQuery query, {
    required String? cwd,
    String? directory,
    String? currentAgent,
    Iterable<ComposerReference> selected = const [],
    Future<Map<String, String>> Function(Iterable<String> profiles)?
    labelsForAgents,
    required void Function() requireCurrent,
  }) async {
    requireCurrent();
    final term = query.term;
    final fileQuery = term.startsWith('file:') || term.startsWith('folder:');
    final items = <MentionCandidate>[];
    if (directory == null &&
        !fileQuery &&
        (!term.contains('/') || query.isQuotedAgent)) {
      final agents = await repository.agents();
      requireCurrent();
      final labels =
          await labelsForAgents?.call(agents.map((agent) => agent.name)) ??
          const <String, String>{};
      requireCurrent();
      String label(String name) =>
          labels[name] ??
          agents.singleWhere((agent) => agent.name == name).label;
      for (final agent in agents) {
        final search = query.agentSearch.toLowerCase();
        if (!agent.name.toLowerCase().contains(search) &&
            !agent.label.toLowerCase().contains(search) &&
            !label(agent.name).toLowerCase().contains(search)) {
          continue;
        }
        final base = composerAgentToken(label(agent.name));
        final duplicate = agents.any(
          (other) =>
              other.name != agent.name &&
              composerAgentToken(label(other.name)).toLowerCase() ==
                  base.toLowerCase(),
        );
        final claimed = selected.any(
          (ref) => ref.token == base && ref.target != agent.name,
        );
        final token = composerAgentToken(
          label(agent.name),
          qualifier: duplicate || claimed ? agent.name : null,
          target: agent.name,
          claimed: selected,
        );
        items.add(
          MentionCandidate(
            reference: ComposerReference(
              kind: ComposerReferenceKind.agent,
              token: token,
              target: agent.name,
            ),
            label: label(agent.name),
            detail:
                '$token${agent.name == currentAgent ? ' · Current agent' : ''}',
          ),
        );
      }
    }
    if (query.isQuotedAgent) {
      return MentionCompletion(query: query, items: items);
    }
    var path = directory ?? cwd;
    var filter = fileQuery ? term.substring(term.indexOf(':') + 1) : term;
    if (directory == null && filter.contains('/')) {
      filter = filter.replaceAll(RegExp(r'''^[`"']|[`"']$'''), '');
      final c = ServerReferencePath.pathContext;
      final absolute = c.isAbsolute(filter)
          ? c.normalize(filter)
          : (cwd == null ? null : c.normalize(c.join(cwd, filter)));
      if (absolute == null) {
        throw const FormatException('Chat workspace is unavailable.');
      }
      path = filter.endsWith('/') ? absolute : c.dirname(absolute);
      filter = filter.endsWith('/') ? '' : c.basename(absolute);
    }
    if (directory != null) filter = '';
    ServerReferenceDirectory listing;
    try {
      listing = await repository.files.directory(path);
    } catch (_) {
      requireCurrent();
      if (directory != null || fileQuery || term.contains('/')) rethrow;
      return MentionCompletion(
        query: query,
        items: items,
        warning:
            'Server files are unavailable. Agent references are still available.',
      );
    }
    requireCurrent();
    for (final entry in listing.entries) {
      if (!entry.name.toLowerCase().contains(filter.toLowerCase())) continue;
      if (term.startsWith('folder:') && !entry.directory) continue;
      final kind = entry.directory
          ? ComposerReferenceKind.folder
          : ComposerReferenceKind.file;
      String token;
      try {
        token = composerPathToken(kind, entry.path);
      } on FormatException {
        continue;
      }
      items.add(
        MentionCandidate(
          reference: ComposerReference(
            kind: kind,
            token: token,
            target: entry.path,
          ),
          label: entry.name,
          detail: entry.directory ? 'Folder' : '${entry.size} bytes',
        ),
      );
    }
    return MentionCompletion(
      query: query,
      items: items,
      directory: listing.path,
      parent: listing.parent,
    );
  }

  Future<String> prepare(
    String text, {
    required Iterable<ComposerReference> selected,
    required String? cwd,
    required int? contextLimit,
    required void Function() requireCurrent,
  }) async {
    requireCurrent();
    if (!text.contains('@')) return text;
    final agents = await repository.agents();
    requireCurrent();
    final spans = composerReferenceSpans(
      text,
      selected: selected,
      agentNames: agents.map((a) => a.name),
    );
    if (spans.isEmpty) {
      // Stock expands directives inside code too. Preserve authored literal
      // file/folder examples without fetching their contents.
      return RegExp(r'@(?:file:|folder:)').hasMatch(text)
          ? PreparedComposerMessage(message: text, context: '').wireText
          : text;
    }
    if (spans.length > maxReferences) {
      throw const FormatException(
        'Use at most 16 references. Your message is kept.',
      );
    }
    if (hasUnpreparedComposerDirective(text)) {
      throw const FormatException(
        'Send other @ directives separately from selected references.',
      );
    }
    final blocks = <String>[];
    final targets = <ComposerReference>[];
    for (final span in spans) {
      requireCurrent();
      final ref = span.reference;
      if (ref.kind == ComposerReferenceKind.agent) {
        targets.add(ref);
        final agent = agents.where((a) => a.name == ref.target).firstOrNull;
        if (agent == null) {
          throw FormatException(
            '${ref.token} is unavailable. Correct the mention before sending.',
          );
        }
        blocks.add(
          '${ref.token} identifies ${agent.label}, canonical profile '
          '${agent.name}, on this Hermes server. It does not reroute this message. '
          'If the user asks you to contact it, use message_agent only if that tool '
          'is available in this chat; otherwise explain that contact is unavailable.',
        );
        continue;
      }
      if (contextLimit == null || contextLimit <= 0) {
        throw const FormatException(
          'Chat workspace or context limit is unavailable. Retry before sending.',
        );
      }
      final c = ServerReferencePath.pathContext;
      if (!c.isAbsolute(ref.target) && cwd == null) {
        throw const FormatException(
          'Chat workspace is unavailable. Use an absolute path.',
        );
      }
      final requested = c.isAbsolute(ref.target)
          ? c.normalize(ref.target)
          : c.normalize(c.join(cwd!, ref.target));
      final entry = await repository.files.entry(
        requested,
        canonical: selected.any((r) => r.token == ref.token),
        folder: ref.kind == ComposerReferenceKind.folder,
      );
      final target = entry.path;
      targets.add(
        ComposerReference(kind: ref.kind, token: ref.token, target: target),
      );
      requireCurrent();
      if (ref.kind == ComposerReferenceKind.folder) {
        if (!entry.directory) {
          throw FormatException('${ref.token} is no longer a folder.');
        }
        final listing = await _folder(target, target, requireCurrent);
        blocks.add('${ref.token}\n$listing');
      } else {
        if (entry.directory) {
          throw FormatException('${ref.token} is no longer a file.');
        }
        final bytes = await repository.files.bytes(
          entry,
          maxBytes: maxFileBytes,
        );
        requireCurrent();
        if (_binary(entry, bytes)) {
          throw FormatException(
            '${entry.name} cannot be included as text. Choose a text file.',
          );
        }
        var content = utf8.decode(bytes);
        if (span.firstLine != null) {
          final lines = content.split('\n');
          final first = span.firstLine!, last = span.lastLine!;
          if (first < 1 || last < first || first > lines.length) {
            throw FormatException(
              '${ref.token} has an unavailable line range.',
            );
          }
          content = lines
              .sublist(first - 1, last.clamp(first, lines.length))
              .join('\n');
        }
        blocks.add('${ref.token} (server file: $target)\n$content');
      }
    }
    // Stock saved phone-image references must remain outside the JSON envelope
    // so native image extraction can assemble them again on replay.
    final images = PreparedComposerMessage.imageSuffixPattern.firstMatch(text);
    final prepared = PreparedComposerMessage(
      message: images == null ? text : text.substring(0, images.start),
      context: blocks.join('\n\n'),
      references: List.unmodifiable(targets),
      imageReferences: images?.group(0) ?? '',
    );
    final wire = prepared.wireText;
    // Match stock's half-window hard ceiling, including our serialization
    // overhead. This remains an estimate, never reported as measured usage.
    if (contextLimit != null &&
        (wire.runes.length / 4).ceil() > contextLimit ~/ 2) {
      throw const FormatException(
        'Referenced context is too large. Narrow the references before sending.',
      );
    }
    requireCurrent();
    return wire;
  }

  bool _binary(ServerReferenceEntry entry, List<int> bytes) {
    const extensions = {
      '.py',
      '.md',
      '.txt',
      '.json',
      '.yaml',
      '.yml',
      '.toml',
      '.js',
      '.ts',
    };
    final mime = entry.mime ?? '';
    return mime.isNotEmpty &&
            mime != 'application/octet-stream' &&
            !mime.startsWith('text/') &&
            !extensions.contains(
              ServerReferencePath.pathContext.extension(entry.name),
            ) ||
        bytes.take(4096).contains(0);
  }

  Future<String> _folder(
    String target,
    String cwd,
    void Function() requireCurrent,
  ) async {
    final c = ServerReferencePath.pathContext;
    final hits = await repository.ignoredFilePaths(
      target,
      cwd,
      requireCurrent: requireCurrent,
    );
    final entries = <String, ServerReferenceEntry>{};
    final directories = <String>{};
    if (hits != null) {
      final parents = <String, ServerReferenceDirectory>{};
      for (final hit in hits) {
        requireCurrent();
        final parent = c.dirname(hit);
        final listing = parents[parent] ??= await repository.files.directory(
          parent,
        );
        requireCurrent();
        final entry = listing.entries
            .where(
              (e) => e.path == hit && e.name == c.basename(hit) && !e.directory,
            )
            .firstOrNull;
        if (entry == null) {
          throw const FormatException('Folder changed while reading. Retry.');
        }
        entries[hit] = entry;
        var ancestor = parent;
        while (c.isWithin(target, ancestor)) {
          directories.add(ancestor);
          ancestor = c.dirname(ancestor);
        }
      }
    } else {
      final pending = <String>[target];
      final visited = <String>{};
      while (pending.isNotEmpty && entries.length + directories.length < 200) {
        requireCurrent();
        final path = pending.removeLast();
        if (!visited.add(path)) continue;
        final listing = await repository.files.directory(path);
        requireCurrent();
        final visible =
            listing.entries
                .where(
                  (e) =>
                      !e.name.startsWith('.') &&
                      e.name != '__pycache__' &&
                      (e.path == target || c.isWithin(target, e.path)),
                )
                .toList()
              ..sort((a, b) => a.name.compareTo(b.name));
        final children = <String>[];
        for (final entry in visible) {
          if (entries.length + directories.length >= 200) break;
          if (entry.directory) {
            directories.add(entry.path);
            children.add(entry.path);
          } else {
            entries[entry.path] = entry;
          }
        }
        pending.addAll(children.reversed);
      }
    }
    final lines = <String>[target.endsWith('/') ? target : '$target/'];
    final all = {...directories, ...entries.keys}.toList()..sort();
    for (final path in all) {
      requireCurrent();
      final relative = c.relative(path, from: target);
      final indent = '  ' * (c.split(relative).length - 1);
      if (directories.contains(path)) {
        lines.add('$indent- ${c.basename(path)}/');
        continue;
      }
      final entry = entries[path]!;
      var metadata = '${entry.size} bytes';
      if (entry.size! <= maxFileBytes) {
        try {
          final bytes = await repository.files.bytes(
            entry,
            maxBytes: maxFileBytes,
          );
          requireCurrent();
          if (!_binary(entry, bytes)) {
            metadata = '${bytes.where((b) => b == 10).length + 1} lines';
          }
        } on FormatException {
          /* Stock also uses byte sizes when metadata inspection fails. */
        }
      }
      lines.add('$indent- ${entry.name} ($metadata)');
    }
    if ((hits?.length ?? all.length) >= 200 || all.length >= 200) {
      lines.add('- ...');
    }
    return lines.join('\n');
  }
}
