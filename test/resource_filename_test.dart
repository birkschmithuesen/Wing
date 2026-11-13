import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/presentation/resource_identity.dart';
import 'package:wing/core/theme/wing_theme.dart';
import 'package:wing/core/widgets/resource_filename.dart';

void main() {
  test(
    'display names retain literal filename characters and both separators',
    () {
      expect(
        resourceFileName('/srv/reports/100%?# notes.md'),
        '100%?# notes.md',
      );
      expect(resourceFileName(r'C:\reports\report.md'), 'report.md');
      expect(resourceFileName('trip/report.md'), 'report.md');
      expect(
        resourceFileName('https://example.com/report%20notes.md?q=1#top'),
        'report notes.md',
      );
    },
  );

  for (final target in [
    '/srv/reports/one-long-report-name.md',
    'trip/one-long-report-name.md',
  ]) {
    testWidgets('name reveals only the exact supplied target $target', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(390, 780);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          theme: wingTheme(Brightness.light),
          home: Scaffold(
            body: Padding(
              padding: const EdgeInsets.only(left: 40, top: 120),
              child: SizedBox(
                width: 130,
                child: ResourceFilename(target: target),
              ),
            ),
          ),
        ),
      );
      final name = find.text('one-long-report-name.md');
      final label = tester.widget<Text>(name);
      expect(label.maxLines, 1);
      expect(label.softWrap, false);
      expect(label.overflow, TextOverflow.ellipsis);
      expect(find.text(target), findsNothing);
      final tap = tester.getTopLeft(name) + const Offset(20, 10);
      await tester.tapAt(tap);
      await tester.pumpAndSettle();
      expect(find.text(target), findsOneWidget);
      final popup = tester.getRect(
        find.byWidgetPredicate((widget) => widget is PopupMenuItem<void>),
      );
      expect((popup.top - tap.dy).abs(), lessThan(40));
      expect(popup.width, lessThanOrEqualTo(360));
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('literal filenames and HTTP addresses reveal exact identities', (
    tester,
  ) async {
    for (final target in [
      '/srv/reports/100%?# notes.md',
      'https://example.com/report%20notes.md?q=1#top',
    ]) {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: ResourceFilename(target: target)),
        ),
      );
      final tooltip = target.startsWith('https:')
          ? 'Show resource address'
          : 'Show file path';
      expect(find.byTooltip(tooltip), findsOneWidget);
      await tester.tap(find.byTooltip(tooltip));
      await tester.pumpAndSettle();
      expect(find.text(target), findsOneWidget);
      expect(
        tester.widget<SelectableText>(find.byType(SelectableText)).data,
        target,
      );
      await tester.tapAt(const Offset(700, 500));
      await tester.pumpAndSettle();
    }
  });

  for (final scale in [1.0, 2.0]) {
    testWidgets('viewer header owns compact action placement at $scale', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
          home: Builder(
            builder: (context) => Scaffold(
              appBar: ResourceViewerAppBar(
                context: context,
                title: 'ignored',
                target: '/srv/long/report.md',
                actions: [
                  ResourceViewerAction(
                    label: 'Share file',
                    icon: Icons.share_outlined,
                    onPressed: () {},
                  ),
                ],
              ),
              body: const SizedBox(),
            ),
          ),
        ),
      );
      final action = find.byType(ResourceViewerAction);
      expect(tester.getSize(action), const Size(32, 32));
      expect(
        tester
            .widget<Icon>(
              find.descendant(of: action, matching: find.byType(Icon)),
            )
            .size,
        16,
      );
      if (scale == 2) {
        expect(
          tester.getRect(find.text('report.md')).bottom,
          lessThan(tester.getRect(action).top),
        );
      }
      expect(find.text('report.md'), findsOneWidget);
      expect(find.byTooltip('Share file'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
