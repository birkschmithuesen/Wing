import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/models/settings_edit.dart';
import 'package:wing/core/screens/administration/admin_delegation_model_page.dart';
import 'package:wing/core/screens/administration/admin_hosted_connector_accounts_page.dart';
import 'package:wing/core/screens/administration/admin_settings_page.dart';
import 'package:wing/core/theme/wing_theme.dart';
import 'package:wing/core/widgets/compact_switch.dart';
import 'package:wing/core/widgets/studio_form_actions.dart';
import 'package:wing/core/widgets/studio_loading.dart';
import 'administration_fixture.dart';
import 'form_family_capture.dart';
import 'hosted_connector_fixture.dart';

/// The same production controls are exercised on host and disposable Android.
/// Account responses are fixtures; this never authorizes an external account.
void registerUpstreamCapabilitiesScenarios({
  bool native = false,
  Future<void> Function(WidgetTester tester, String name, bool keyboard)?
  nativeCapture,
}) {
  Future<void> capture(
    WidgetTester tester,
    String name, {
    bool keyboard = false,
  }) async {
    if (native) {
      await nativeCapture?.call(tester, name, keyboard);
    } else {
      await captureFormFamily(tester, name);
    }
  }

  if (!native) setUpAll(loadFormFamilyFonts);
  Future<void> show(
    WidgetTester tester,
    Widget page,
    Brightness brightness,
    double scale,
  ) async {
    if (!native) {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
    }
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
          home: page,
        ),
      ),
    );
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 5),
    );
  }

  testWidgets(
    'Connected apps retain named-account drafts through held failure and retry',
    (tester) async {
      if (!native) addTearDown(tester.view.reset);
      for (final brightness in Brightness.values) {
        for (final scale in [1.0, 2.0]) {
          final fixture = HostedConnectorFixture();
          await show(
            tester,
            AdminHostedConnectorAccountsPage(
              profile: fixture.server.profile('personal'),
            ),
            brightness,
            scale,
          );
          await tester.scrollUntilVisible(
            find.text('personal'),
            160,
            scrollable: find.byType(Scrollable).first,
          );
          expect(find.text('personal'), findsOneWidget);
          await tester.scrollUntilVisible(
            find.text('work'),
            -160,
            scrollable: find.byType(Scrollable).first,
          );
          expect(find.text('work'), findsOneWidget);
          fixture.accountsGate = Completer<void>();
          await tester.tap(find.byTooltip('Refresh connected apps'));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 100));
          expect(find.byType(StudioLoading), findsOneWidget);
          expect(
            tester
                .getRect(find.byType(StudioLoading))
                .overlaps(
                  Offset.zero &
                      tester.view.physicalSize / tester.view.devicePixelRatio,
                ),
            isTrue,
          );
          expect(find.text('work'), findsOneWidget);
          fixture.accountsGate!.complete();
          await tester.pumpAndSettle(
            const Duration(milliseconds: 100),
            EnginePhase.sendSemanticsUpdate,
            const Duration(seconds: 5),
          );
          fixture.accountsGate = null;
          await tester.ensureVisible(find.byTooltip('Rename work'));
          await tester.tap(find.byTooltip('Rename work'));
          await tester.pumpAndSettle(
            const Duration(milliseconds: 100),
            EnginePhase.sendSemanticsUpdate,
            const Duration(seconds: 5),
          );
          await tester.enterText(
            find.widgetWithText(TextField, 'Account name'),
            'work-calendar',
          );
          await tester.pumpAndSettle(
            const Duration(milliseconds: 100),
            EnginePhase.sendSemanticsUpdate,
            const Duration(seconds: 5),
          );
          expect(
            find.byTooltip('Save account name').hitTestable(),
            findsOneWidget,
          );
          await capture(
            tester,
            'hosted-account-${brightness.name}-$scale-keyboard',
            keyboard: true,
          );
          fixture.mutationGate = Completer<void>();
          fixture.failMutation = true;
          await tester.tap(find.byTooltip('Save account name'));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 100));
          expect(
            find
                .descendant(
                  of: find.byType(StudioFormActions),
                  matching: find.byType(CircularProgressIndicator),
                )
                .hitTestable(),
            findsOneWidget,
          );
          await capture(
            tester,
            'hosted-account-${brightness.name}-$scale-pending',
          );
          fixture.mutationGate!.complete();
          await tester.pumpAndSettle(
            const Duration(milliseconds: 100),
            EnginePhase.sendSemanticsUpdate,
            const Duration(seconds: 5),
          );
          expect(find.text('work-calendar'), findsOneWidget);
          expect(
            find.textContaining('Refresh accounts before trying again.'),
            findsWidgets,
          );
          await capture(
            tester,
            'hosted-account-${brightness.name}-$scale-failed',
          );
          fixture.failMutation = false;
          fixture.mutationGate = null;
          final retry = find.descendant(
            of: find.byType(BottomSheet),
            matching: find.text('Retry'),
          );
          await tester.ensureVisible(retry);
          await tester.tap(retry);
          await tester.pumpAndSettle(
            const Duration(milliseconds: 100),
            EnginePhase.sendSemanticsUpdate,
            const Duration(seconds: 5),
          );
          await tester.tap(find.byTooltip('Save account name'));
          await tester.pumpAndSettle(
            const Duration(milliseconds: 100),
            EnginePhase.sendSemanticsUpdate,
            const Duration(seconds: 5),
          );
          expect(find.byType(BottomSheet), findsNothing);
          expect(fixture.accounts.first['alias'], 'work-calendar');
          expect(fixture.accounts.last['alias'], 'personal');
          expect(
            fixture.calls.where(
              (call) => call.$1 == 'connectors.accounts.rename',
            ),
            hasLength(2),
          );
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pumpAndSettle(
            const Duration(milliseconds: 100),
            EnginePhase.sendSemanticsUpdate,
            const Duration(seconds: 5),
          );
        }
      }
    },
  );

  testWidgets(
    'Subagent route and prepared compression save through production controls',
    (tester) async {
      if (!native) addTearDown(tester.view.reset);
      for (final brightness in Brightness.values) {
        for (final scale in [1.0, 2.0]) {
          final fixture = AdministrationFixture();
          fixture.configs['personal']!['delegation'] = <String, dynamic>{
            'model': 'old',
            'provider': 'custom',
            'base_url': 'https://example.invalid',
            'api_key': 'synthetic',
            'api_mode': 'chat_completions',
          };
          fixture.configs['personal']!['compression'] = <String, dynamic>{
            'prepare_ahead': false,
          };
          final profile = fixture.server.profile('personal');
          await show(
            tester,
            AdminDelegationModelPage(profile: profile),
            brightness,
            scale,
          );
          await tester.enterText(
            find.byKey(const Key('delegation-model-search')),
            'second',
          );
          await tester.pumpAndSettle(
            const Duration(milliseconds: 100),
            EnginePhase.sendSemanticsUpdate,
            const Duration(seconds: 5),
          );
          // At enlarged text with the native keyboard open, the row can be
          // taller than the list viewport. Its geometric centre is not the
          // visible label. Drive the actual visible option, then require Save
          // admission before testing the held write.
          final option = find.descendant(
            of: find.byKey(const Key('delegation-model-example-second')),
            matching: find.text('Second'),
          );
          await revealUpstreamControl(tester, option);
          await tester.tap(option.hitTestable());
          await tester.pumpAndSettle(
            const Duration(milliseconds: 100),
            EnginePhase.sendSemanticsUpdate,
            const Duration(seconds: 5),
          );
          await capture(
            tester,
            'delegation-${brightness.name}-$scale-keyboard',
            keyboard: true,
          );
          fixture.writeGate = Completer<void>();
          expect(
            tester
                .widget<StudioFormActions>(find.byType(StudioFormActions))
                .onConfirm,
            isNotNull,
          );
          await tester.tap(find.byTooltip('Save subagent model'));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 100));
          expect(
            find.byType(CircularProgressIndicator).hitTestable(),
            findsOneWidget,
          );
          await capture(tester, 'delegation-${brightness.name}-$scale-pending');
          fixture.writeGate!.complete();
          await tester.pumpAndSettle(
            const Duration(milliseconds: 100),
            EnginePhase.sendSemanticsUpdate,
            const Duration(seconds: 5),
          );
          expect(
            setting(fixture.configs['personal']!, 'delegation.model'),
            'second',
          );
          expect(
            setting(fixture.configs['personal']!, 'delegation.provider'),
            'example',
          );
          expect(
            setting(fixture.configs['personal']!, 'delegation.api_key'),
            '',
          );
          expect(find.text('example / second'), findsOneWidget);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
          fixture.writeGate = null;
          await show(
            tester,
            AdminSettingsPage(
              profile: profile,
              title: 'Compression',
              fields: compressionFields,
            ),
            brightness,
            scale,
          );
          final toggle = find.byType(CompactSwitchListTile);
          expect(tester.widget<CompactSwitchListTile>(toggle).value, isFalse);
          final switchFace = find.descendant(
            of: toggle,
            matching: find.byType(CompactSwitch),
          );
          await tester.ensureVisible(switchFace);
          await tester.pumpAndSettle(
            const Duration(milliseconds: 100),
            EnginePhase.sendSemanticsUpdate,
            const Duration(seconds: 5),
          );
          expect(switchFace.hitTestable(), findsOneWidget);
          await tester.tap(switchFace);
          await tester.pumpAndSettle(
            const Duration(milliseconds: 100),
            EnginePhase.sendSemanticsUpdate,
            const Duration(seconds: 5),
          );
          await tester.tap(find.byTooltip('Save changes'));
          await tester.pumpAndSettle(
            const Duration(milliseconds: 100),
            EnginePhase.sendSemanticsUpdate,
            const Duration(seconds: 5),
          );
          expect(
            setting(fixture.configs['personal']!, 'compression.prepare_ahead'),
            isTrue,
          );
          await capture(
            tester,
            'prepared-compression-${brightness.name}-$scale',
          );
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pumpAndSettle(
            const Duration(milliseconds: 100),
            EnginePhase.sendSemanticsUpdate,
            const Duration(seconds: 5),
          );
        }
      }
    },
  );
}

/// Reveal a scenario's real control before dispatching its single tap.
Future<void> revealUpstreamControl(WidgetTester tester, Finder control) async {
  final deadline = tester.binding.clock.fromNowBy(const Duration(seconds: 5));
  do {
    // Native keyboard metrics can arrive after ensureVisible computes its
    // scroll offset. Advance layout, then observe the actual tap target.
    await tester.ensureVisible(control);
    await tester.pump(const Duration(milliseconds: 100));
  } while (control.hitTestable().evaluate().isEmpty &&
      tester.binding.clock.now().isBefore(deadline));
  expect(control.hitTestable(), findsOneWidget);
}
