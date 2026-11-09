import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/widgets/background_markdown_content.dart';
import 'package:wing/core/widgets/profile_tool_activity.dart';
import 'package:wing/core/widgets/studio_loading.dart';

extension PumpMarkdownWidget on WidgetTester {
  /// Reopened lazy rows can start another Markdown worker during restoration.
  /// Let real worker I/O complete while the rendered history state is pending.
  Future<void> settleTranscript() async {
    for (var attempt = 0; attempt < 200; attempt++) {
      await pump(const Duration(milliseconds: 16));
      final pending = stateList<BackgroundMarkdownContentState>(
        find.byType(BackgroundMarkdownContent, skipOffstage: false),
      ).any((state) => state.pending);
      final loading = widgetList<StudioPageLoading>(
        find.byType(StudioPageLoading),
      ).any((widget) => widget.active && widget.label == 'Loading history');
      if (!pending && !loading) return;
      await runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
    }
    fail('Conversation history and Markdown restoration did not settle.');
  }

  Future<void> pumpMarkdownWidget(Widget widget) async {
    await pumpWidget(widget);
    await settleMarkdown();
  }

  Future<void> openLiveActivity({bool tools = true}) async {
    final section = find.byKey(const ValueKey('live-activity'));
    if (section.evaluate().isEmpty) {
      final retained = find.byKey(
        const ValueKey('live-activity'),
        skipOffstage: false,
      );
      if (retained.evaluate().isEmpty) return;
      final latest = find.byKey(const ValueKey('jump-to-latest'));
      expect(latest, findsOneWidget);
      await tap(latest);
      await pump();
      await pump(const Duration(milliseconds: 300));
    }
    final toggle = find.descendant(
      of: section,
      matching: find.byKey(const ValueKey('live-activity-toggle')),
    );
    if (toggle.evaluate().isNotEmpty &&
        find
            .descendant(of: toggle, matching: find.byIcon(Icons.chevron_right))
            .evaluate()
            .isNotEmpty) {
      await ensureVisible(toggle);
      await pump(const Duration(milliseconds: 300));
      final caret = find.descendant(
        of: toggle,
        matching: find.byIcon(Icons.chevron_right),
      );
      expect(caret.hitTestable(), findsOneWidget);
      await tap(caret);
      await pump();
      await pump(const Duration(milliseconds: 300));
    }
    if (!tools) return;
    final disclosures = find.descendant(
      of: section,
      matching: find.byType(ProfileActivitySection),
    );
    for (final element in disclosures.evaluate().toList()) {
      final disclosure = find.byElementPredicate(
        (candidate) => candidate == element,
      );
      final label = widget<ProfileActivitySection>(disclosure).label;
      final header = find.ancestor(
        of: find.descendant(of: disclosure, matching: find.text(label)),
        matching: find.byType(ListTile),
      );
      expect(header, findsOneWidget);
      final expand = find.descendant(
        of: header,
        matching: find.byIcon(Icons.keyboard_arrow_right_rounded),
      );
      if (expand.evaluate().isEmpty) {
        expect(
          find.descendant(
            of: header,
            matching: find.byIcon(Icons.keyboard_arrow_down_rounded),
          ),
          findsOneWidget,
        );
        continue;
      }
      await Scrollable.ensureVisible(this.element(header), alignment: .5);
      await pump(const Duration(milliseconds: 300));
      expect(header.hitTestable(at: const Alignment(-.9, 0)), findsOneWidget);
      await tapAt(getRect(header).centerLeft + const Offset(12, 0));
      await pump();
      await pump(const Duration(milliseconds: 300));
      await settleMarkdown();
      await pump();
    }
  }

  Future<void> settleMarkdown() async {
    for (var attempt = 0; attempt < 200; attempt++) {
      final pending = stateList<BackgroundMarkdownContentState>(
        find.byType(BackgroundMarkdownContent),
      ).any((state) => state.pending);
      if (!pending) return;
      await runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await pump(const Duration(milliseconds: 16));
    }
    fail('Background Markdown did not render the latest complete snapshot.');
  }
}
