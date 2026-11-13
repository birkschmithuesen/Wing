import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:wing/core/widgets/bot_mention_scope.dart';
import 'package:wing/core/widgets/markdown_message_content.dart';
import 'helpers/pump_markdown_widget.dart';

void main() {
  final scope = BotMentionScope(
    names: {'bot_default': 'Default', 'bot_pace': 'Pace'},
    child: const SizedBox(),
  );
  test(
    'known identities render readable names and preserve literal boundaries',
    () {
      const source =
          '@bot_default, @bot_pace! @unknown @bot_default_extra '
          'person@bot_default.com https://example.com/@bot_default '
          '`@bot_default`\n```\n@bot_pace\n```';
      final result = scope.text(source, Colors.teal);
      expect(
        result.toPlainText(),
        source
            .replaceFirst('@bot_default,', '@Default,')
            .replaceFirst('@bot_pace!', '@Pace!'),
      );
      final mentions = result.children!
          .whereType<TextSpan>()
          .where((span) => span.style != null)
          .toList();
      expect(mentions.map((span) => span.text), ['@Default', '@Pace']);
      expect(
        mentions.every(
          (span) =>
              span.style!.fontWeight == FontWeight.bold &&
              span.style!.color == Colors.teal,
        ),
        isTrue,
      );
    },
  );
  test('Markdown annotations leave code, links and original AST untouched', () {
    final original = md.Document(encodeHtml: false).parseLines([
      '@bot_default, **@bot_pace** `@bot_pace` [@bot_default](https://example.com/@bot_pace)',
    ]);
    final rendered = scope.prose(original);
    expect(original.single.textContent, contains('@bot_default'));
    final children = (rendered.single as md.Element).children!;
    expect(
      children
          .whereType<md.Element>()
          .where((node) => node.tag == BotMentionScope.tag)
          .single
          .textContent,
      '@Default',
    );
    expect(
      children
          .whereType<md.Element>()
          .firstWhere((node) => node.tag == 'code')
          .textContent,
      '@bot_pace',
    );
    expect(
      children
          .whereType<md.Element>()
          .firstWhere((node) => node.tag == 'a')
          .textContent,
      '@bot_default',
    );
    expect(rendered.single.textContent, contains('@Pace'));
  });
  testWidgets('shared Markdown paragraphs retain selectable styled mentions', (
    tester,
  ) async {
    await tester.pumpMarkdownWidget(
      MaterialApp(
        home: Scaffold(
          body: BotMentionScope(
            names: scope.names,
            child: const MarkdownMessageContent(
              data: '@bot_default, ask **@bot_pace**. `@bot_default`',
            ),
          ),
        ),
      ),
    );
    final texts = tester.widgetList<SelectableText>(
      find.byType(SelectableText),
    );
    expect(
      texts.map((text) => text.textSpan?.toPlainText() ?? text.data).join(),
      contains('@Default, ask @Pace. @bot_default'),
    );
    expect(tester.takeException(), isNull);
  });
}
