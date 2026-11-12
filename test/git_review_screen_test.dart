import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/screens/git_review_screen.dart';
import 'package:wing/core/services/git_review_session.dart';
import 'package:wing/core/theme/wing_theme.dart';
import 'package:wing/core/widgets/studio_loading.dart';
import 'support/git_review_fixture.dart';
import 'support/form_family_capture.dart';

void main() {
  setUpAll(() async {
    await loadFormFamilyFonts();
    if (const bool.fromEnvironment('CAPTURE_FORM_FAMILY')) {
      const directory = String.fromEnvironment('CAPTURE_FONT_DIR');
      await (FontLoader('monospace')..addFont(
            File(
              '$directory/RobotoMono-Regular.ttf',
            ).readAsBytes().then(ByteData.sublistView),
          ))
          .load();
    }
  });
  testWidgets('leaving a diff retires held clipboard failure', (tester) async {
    final fixture = GitReviewFixture();
    final session = GitReviewSession(
      server: fixture.server,
      resolveWorkspace: () async => '/work/wing',
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: wingTheme(Brightness.dark),
        home: GitReviewScreen(session: session, scope: 'Phone review'),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('lib/phone.dart'));
    await tester.pumpAndSettle();
    final held = Completer<void>();
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') await held.future;
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await tester.tap(find.byTooltip('Copy hunk reference'));
    await tester.pump();
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    await tester.tap(find.text('notes/phone-review.txt'));
    await tester.pumpAndSettle();
    held.completeError(StateError('Clipboard unavailable'));
    await tester.pumpAndSettle();
    expect(
      find.text('The reference could not be copied. Try again.'),
      findsNothing,
    );
    expect(find.text('Reference copied'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('Git review controls ${brightness.name} $scale', (
        tester,
      ) async {
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final fixture = GitReviewFixture()..listGate = Completer<void>();
        final session = GitReviewSession(
          server: fixture.server,
          resolveWorkspace: () async => '/work/wing',
        );
        await tester.pumpWidget(
          RepaintBoundary(
            key: formFamilyCapture,
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: wingTheme(brightness),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: TextScaler.linear(scale)),
                child: child!,
              ),
              home: GitReviewScreen(
                session: session,
                scope: 'Personal · Phone improvements',
              ),
            ),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 120));
        expect(find.byType(StudioLoading), findsOneWidget);
        await captureFormFamily(
          tester,
          'git-loading-${brightness.name}-$scale',
        );
        fixture.listGate!.complete();
        await tester.pumpAndSettle();
        expect(find.text('lib/phone.dart'), findsOneWidget);
        await captureFormFamily(tester, 'git-files-${brightness.name}-$scale');
        fixture.diffGate = Completer<void>();
        await tester.ensureVisible(find.text('lib/phone.dart'));
        await tester.tap(find.text('lib/phone.dart'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 120));
        expect(find.byType(StudioLoading), findsOneWidget);
        fixture.fail = true;
        fixture.diffGate!.complete();
        await tester.pumpAndSettle();
        expect(find.textContaining('This diff could not load'), findsOneWidget);
        fixture.fail = false;
        await tester.tap(find.byTooltip('Reload diff'));
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text('Staged'));
        await tester.tap(find.text('Staged'));
        await tester.pumpAndSettle();
        expect(fixture.requests.last.$3['staged'], 'true');
        await captureFormFamily(tester, 'git-diff-${brightness.name}-$scale');
        String? copied;
        final held = Completer<void>();
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          (call) async {
            if (call.method == 'Clipboard.setData') {
              copied = (call.arguments as Map)['text'] as String;
              await held.future;
            }
            return null;
          },
        );
        addTearDown(
          () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            SystemChannels.platform,
            null,
          ),
        );
        final copy = find.byTooltip('Copy hunk reference');
        await tester.scrollUntilVisible(
          copy,
          160,
          scrollable: find
              .descendant(
                of: find.byType(CustomScrollView),
                matching: find.byType(Scrollable),
              )
              .first,
        );
        await tester.tap(copy);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 120));
        expect(find.byType(StudioLoading), findsOneWidget);
        held.complete();
        await tester.pumpAndSettle();
        expect(copied, contains('lib/phone.dart (staged)'));
        expect(find.text('Reference copied'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      });
    }
  }
}
