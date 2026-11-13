import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:markdown/markdown.dart' as md;

import '../models/composer_reference.dart';

/// A room's frozen member identities, used only for message presentation.
class BotMentionScope extends InheritedWidget {
  BotMentionScope({
    super.key,
    required Map<String, String> names,
    required super.child,
  }) : names = Map.unmodifiable(names);

  final Map<String, String> names;
  static BotMentionScope? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<BotMentionScope>();
  static const tag = 'wing-bot-mention';

  @override
  bool updateShouldNotify(BotMentionScope oldWidget) =>
      !mapEquals(names, oldWidget.names);

  List<ComposerReferenceSpan> _spans(String text) =>
      composerReferenceSpans(
            text,
            selected: [
              for (final entry in names.entries)
                ComposerReference(
                  kind: ComposerReferenceKind.agent,
                  token: entry.key.startsWith('@')
                      ? entry.key
                      : '@${entry.key}',
                  target: entry.value,
                ),
            ],
          )
          .where((span) => span.reference.kind == ComposerReferenceKind.agent)
          .toList();

  TextSpan text(String source, Color color) {
    var offset = 0;
    final children = <TextSpan>[];
    for (final span in _spans(source)) {
      children.add(TextSpan(text: source.substring(offset, span.start)));
      children.add(
        TextSpan(
          text: '@${span.reference.target}',
          style: TextStyle(color: color, fontWeight: FontWeight.bold),
        ),
      );
      offset = span.end;
    }
    children.add(TextSpan(text: source.substring(offset)));
    return TextSpan(children: children);
  }

  /// Decorate resolved prose, never code, link labels/targets or image metadata.
  List<md.Node> prose(List<md.Node> nodes) => [
    for (final node in nodes)
      if (node is md.Text)
        ..._textNodes(node.text)
      else if (node is md.Element &&
          !{'code', 'pre', 'a', 'img'}.contains(node.tag) &&
          node.children != null)
        (md.Element(node.tag, prose(node.children!))
          ..attributes.addAll(node.attributes))
      else
        node,
  ];

  List<md.Node> _textNodes(String source) {
    var offset = 0;
    final nodes = <md.Node>[];
    for (final span in _spans(source)) {
      nodes.add(md.Text(source.substring(offset, span.start)));
      nodes.add(md.Element.text(tag, '@${span.reference.target}'));
      offset = span.end;
    }
    nodes.add(md.Text(source.substring(offset)));
    return nodes;
  }
}

class BotMentionBuilder extends MarkdownElementBuilder {
  @override
  Widget visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) => RichText(
    text: TextSpan(
      text: element.textContent,
      style: parentStyle?.copyWith(
        color: Theme.of(context).colorScheme.primary,
        fontWeight: FontWeight.bold,
      ),
    ),
  );
}
