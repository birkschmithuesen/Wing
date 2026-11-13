import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/services/server_connection_status.dart';
import 'package:wing/core/theme/wing_theme.dart';
import 'package:wing/core/widgets/workspace_connection_status.dart';
import 'package:wing/core/widgets/studio_error.dart';
import 'package:wing/core/widgets/studio_loading.dart';
import 'package:wing/core/widgets/server_connection_label.dart';
import 'package:wing/core/widgets/wing_app_bar.dart';
import 'support/form_family_capture.dart';

void main() {
  setUpAll(loadFormFamilyFonts);
  late ServerConnectionStatus status;

  setUp(() {
    status = ServerConnectionStatus('Host')
      ..accessAvailable()
      ..liveChanged('chat', true);
  });
  tearDown(() => status.dispose());

  Future<void> render(
    WidgetTester tester, {
    bool showHint = true,
    bool reducedMotion = false,
    Brightness brightness = Brightness.light,
    double scale = 1,
  }) => tester.pumpWidget(
    MaterialApp(
      theme: wingTheme(brightness),
      debugShowCheckedModeBanner: false,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          disableAnimations: reducedMotion,
          textScaler: TextScaler.linear(scale),
        ),
        child: RepaintBoundary(key: formFamilyCapture, child: child!),
      ),
      home: Builder(
        builder: (context) => Scaffold(
          appBar: WingAppBar(
            context: context,
            title: const Text('Recents'),
            contextRow: ServerConnectionLabel(
              label: status.label,
              status: status,
            ),
          ),
          body: Column(
            children: [
              WorkspaceConnectionStatus(status: status, showHint: showHint),
              const Text('Retained recent chat'),
            ],
          ),
        ),
      ),
    ),
  );

  final bar = find.byKey(const ValueKey('workspace-connection-status'));

  testWidgets('held recovery pulses above retained Recents immediately', (
    tester,
  ) async {
    await render(tester);
    final card = find.text('Retained recent chat');
    final position = tester.getRect(card);
    status.beginRecovery('chat');
    await tester.pump();
    await tester.pump();
    expect(find.byType(StudioLoading), findsOneWidget);
    expect(tester.getRect(card), position);
    await tester.pump(const Duration(seconds: 12));
    expect(find.byType(StudioLoading), findsOneWidget);
    expect(find.textContaining('Reconnecting'), findsNothing);
    expect(find.textContaining('Your draft stays here'), findsNothing);
    expect(tester.getSize(bar).height, 0);
    expect(tester.getRect(card), position);
    status.endRecovery('chat');
    await tester.pump();
    await tester.pumpAndSettle();
    expect(find.byType(StudioLoading), findsNothing);
    expect(tester.getRect(card), position);
  });

  testWidgets('short reconnects never open the connection bar', (tester) async {
    await render(tester);
    expect(tester.getSize(bar).height, 0);
    status.beginRecovery('chat');
    await tester.pump(const Duration(seconds: 1));
    expect(tester.getSize(bar).height, 0);
    status.endRecovery('chat');
    await tester.pump(const Duration(seconds: 2));
    expect(tester.getSize(bar).height, 0);
    expect(find.textContaining('Reconnecting'), findsNothing);
  });

  testWidgets(
    'connection notice animates both ways and hides stale semantics',
    (tester) async {
      final semantics = tester.ensureSemantics();
      await render(tester);
      status.beginRecovery('chat');
      status.failRecovery('chat', 'History unavailable');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));
      final entering = tester.getSize(bar).height;
      expect(entering, greaterThan(0));
      await tester.pump(const Duration(milliseconds: 200));
      final expanded = tester.getSize(bar).height;
      expect(expanded, greaterThan(entering));
      expect(find.bySemanticsLabel(RegExp('Chat unavailable')), findsOneWidget);

      status.endRecovery('chat');
      await tester.pump();
      expect(find.bySemanticsLabel(RegExp('Chat unavailable')), findsNothing);
      await tester.pump(const Duration(milliseconds: 60));
      expect(tester.getSize(bar).height, inExclusiveRange(0, expanded));
      await tester.pumpAndSettle();
      expect(tester.getSize(bar).height, 0);

      status.failRecovery('chat', 'History unavailable');
      await tester.pumpAndSettle();
      expect(find.text('Chat unavailable'), findsOneWidget);
      await render(tester, showHint: false);
      await tester.pumpAndSettle();
      expect(tester.getSize(bar).height, 0);
      expect(find.text('Chat unavailable'), findsNothing);
      await render(tester);
      await tester.pumpAndSettle();
      expect(tester.getSize(bar).height, expanded);
      expect(tester.takeException(), isNull);
      semantics.dispose();
    },
  );

  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('local connection repair ${brightness.name} $scale', (
        tester,
      ) async {
        tester.view.physicalSize = Size(scale == 2 ? 320 : 390, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await render(tester, brightness: brightness, scale: scale);
        status.forgetLive('chat');
        await tester.pumpAndSettle();
        expect(status.phase, ServerConnectionPhase.limited);
        expect(find.byType(StudioError), findsNothing);

        status.observeChatEndpoint(false);
        await tester.pumpAndSettle();
        expect(find.byType(StudioError), findsOneWidget);
        expect(find.text('Chat address needs changing'), findsOneWidget);
        await captureFormFamily(
          tester,
          'workspace-endpoint-error-${brightness.name}-$scale',
        );
        await tester.tap(
          find.byKey(const ValueKey('connection-status-target')),
        );
        await tester.pumpAndSettle();
        expect(find.text('Connection details'), findsOneWidget);
        await tester.tap(find.byTooltip('Close connection details'));
        await tester.pumpAndSettle();

        status.observeChatEndpoint(true);
        status.liveChanged('chat', true);
        status.failRecovery('chat', 'History unavailable');
        await tester.pumpAndSettle();
        expect(find.byType(StudioError), findsOneWidget);
        expect(find.text('Chat unavailable'), findsOneWidget);
        await captureFormFamily(
          tester,
          'workspace-recovery-error-${brightness.name}-$scale',
        );
        expect(tester.takeException(), isNull);
      });
    }
  }

  for (final reducedMotion in [false, true]) {
    testWidgets(
      'recovery survives overlapping owners with hidden hints motion=$reducedMotion',
      (tester) async {
        final semantics = tester.ensureSemantics();
        await render(tester, showHint: false, reducedMotion: reducedMotion);
        status.beginRecovery('chat');
        await tester.pump();
        await tester.pump();
        expect(find.byType(StudioLoading), findsOneWidget);
        expect(find.bySemanticsLabel('Reconnecting'), findsOneWidget);
        status.beginRecovery('other');
        status.endRecovery('chat');
        await tester.pump();
        await tester.pump();
        expect(find.byType(StudioLoading), findsOneWidget);
        expect(tester.getSize(bar).height, 0);
        status.failRecovery('other', 'History unavailable');
        await tester.pump();
        await tester.pumpAndSettle();
        expect(find.byType(StudioLoading), findsNothing);
        expect(tester.getSize(bar).height, 0);
        expect(find.bySemanticsLabel('Reconnecting'), findsNothing);
        semantics.dispose();
      },
    );
  }
}
