import 'package:wing/core/models/transcript_message.dart';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/theme/profile_markdown_style.dart';
import 'package:wing/core/theme/profile_workspace_theme.dart';
import 'package:wing/core/widgets/profile_message.dart';

import 'helpers/pump_markdown_widget.dart';

const sample =
    '## Keep the review focused\n\n'
    'The landing page is the current review. Other routes are **future work**.\n\n'
    '> Navigation currently opens the prototype. This matters before publishing, '
    'but it should not interrupt the landing-page review.\n\n'
    '### Next steps\n\n- Review the `/target/` landing page.\n- Keep the agreed scope.\n\n'
    '---\n\n| Area | Status |\n| --- | --- |\n| Landing page | In review |\n| Other routes | Planned |';

Iterable<TextStyle> quoteStyles(
  InlineSpan span, [
  TextStyle parent = const TextStyle(),
]) sync* {
  final style = parent.merge(span.style);
  if (span is TextSpan) {
    if (span.text?.contains('Navigation currently') == true) yield style;
    for (final child in span.children ?? <InlineSpan>[]) {
      yield* quoteStyles(child, style);
    }
  }
}

void main() {
  const preview = bool.fromEnvironment('MARKDOWN_PREVIEW');
  if (preview) {
    setUpAll(() async {
      const root = String.fromEnvironment('PREVIEW_FONT_ROOT');
      for (final entry in {
        'Roboto': 'roboto-regular.ttf',
        'MaterialIcons': 'MaterialIcons-Regular.otf',
      }.entries) {
        await (FontLoader(entry.key)..addFont(
              File(
                '$root/${entry.value}',
              ).readAsBytes().then(ByteData.sublistView),
            ))
            .load();
      }
      const mono = String.fromEnvironment('PREVIEW_MONO_FONT');
      if (mono.isNotEmpty) {
        await (FontLoader(
          'monospace',
        )..addFont(File(mono).readAsBytes().then(ByteData.sublistView))).load();
      }
    });
  }
  for (final brightness in Brightness.values) {
    for (final accent in WorkspaceAccent.values) {
      test(
        'quote contrast and neutral decoration ${brightness.name}/${accent.name}',
        () {
          final theme = profileWorkspaceTheme(
            ThemeData(
              brightness: brightness,
              textTheme: Typography.material2021().englishLike,
            ),
            accent: accent,
          );
          final sheet = profileMarkdownStyle(theme);
          final decoration = sheet.blockquoteDecoration! as BoxDecoration;
          expect(decoration.color, isNull);
          expect((decoration.border! as Border).left.width, 3);
          final luminances = [
            sheet.blockquote!.foreground!.color.computeLuminance(),
            theme.colorScheme.surface.computeLuminance(),
          ]..sort();
          expect(
            (luminances.last + 0.05) / (luminances.first + 0.05),
            greaterThanOrEqualTo(4.5),
          );
          expect(
            (sheet.horizontalRuleDecoration! as BoxDecoration)
                .border!
                .dimensions
                .resolve(TextDirection.ltr)
                .top,
            1,
          );
        },
      );
    }
    for (final scale in [1.0, 1.6]) {
      testWidgets('rendered quotes stay muted and readable $brightness/$scale', (
        tester,
      ) async {
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final theme = profileWorkspaceTheme(ThemeData(brightness: brightness));
        await tester.pumpMarkdownWidget(
          MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: theme,
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(scale)),
              child: child!,
            ),
            home: Scaffold(
              body: SafeArea(
                child: SingleChildScrollView(
                  padding: EdgeInsets.all(16),
                  child: ProfileMessage(
                    message: TranscriptMessage.fromRow({
                      'role': 'assistant',
                      'content': sample,
                    }),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final styles = tester
            .widgetList<SelectableText>(find.byType(SelectableText))
            .where((widget) => widget.textSpan != null)
            .expand((widget) => quoteStyles(widget.textSpan!))
            .toList();
        expect(styles, isNotEmpty);
        for (final style in styles) {
          expect(
            (style.foreground?.color ?? style.color)!.toARGB32(),
            theme.colorScheme.onSurfaceVariant.toARGB32(),
          );
          expect(style.fontStyle, FontStyle.italic);
        }
        expect(
          (tester
                      .widget<MarkdownBody>(
                        find.byWidgetPredicate(
                          (widget) =>
                              widget is MarkdownBody && widget.data == sample,
                        ),
                      )
                      .styleSheet!
                      .blockquoteDecoration!
                  as BoxDecoration)
              .color,
          isNull,
        );
        expect(tester.takeException(), isNull);
        if (preview && scale == 1) {
          await expectLater(
            find.byType(MaterialApp),
            matchesGoldenFile(
              Uri.file(
                '${Directory.current.path}/build/markdown-${brightness.name}.png',
              ),
            ),
          );
        }
      });
    }
  }
}
