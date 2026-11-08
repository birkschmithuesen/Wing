import 'dart:convert';
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrintSynchronously;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wing/core/screens/bots/bot_profile_editor.dart';
import 'package:wing/core/screens/bots/bot_group_screen.dart';
import 'package:wing/core/screens/bots/bot_group_context_sheet.dart';
import 'package:wing/core/screens/bots/bots_content.dart';
import 'package:wing/core/screens/bots/bots_create_screen.dart';
import 'package:wing/core/screens/profile_workspace_screen.dart';
import 'package:wing/core/services/app_preferences.dart';
import 'package:wing/core/services/connection_access.dart';
import 'package:wing/core/services/connection_manager.dart';
import 'package:wing/core/services/bots_session.dart';
import 'package:wing/core/services/profile_workspace_controller.dart';
import 'package:wing/core/theme/wing_theme.dart';
import 'package:wing/core/widgets/studio_form_actions.dart';
import 'package:wing/core/widgets/studio_loading.dart';

import '../test/support/administration_fixture.dart';
import '../test/support/bots_fixture.dart';
import '../test/support/profile_browser_fixture.dart';

/// The host injects Android input and captures the actual window. Backend
/// responses come from owned fixtures, including the drawer's loopback HTTP.
Future<void> _native(
  WidgetTester tester,
  String name, {
  String action = 'capture',
  String? text,
  bool? keyboard,
}) async {
  final cache = Directory.systemTemp.path;
  final token = '$name-${DateTime.now().microsecondsSinceEpoch}';
  await File('$cache/wing-bots-stage.json').writeAsString(
    jsonEncode({
      'name': name,
      'token': token,
      'action': action,
      'ime_insets_bottom': tester.view.viewInsets.bottom,
      'text': ?text,
      'keyboard': ?keyboard,
    }),
  );
  final ack = File('$cache/wing-bots-ack');
  final deadline = DateTime.now().add(const Duration(seconds: 45));
  while (DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 100));
    if (await ack.exists() && await ack.readAsString() == token) {
      // The roster intentionally contains running work. Its Wing pulse must
      // remain active; native acknowledgment does not require global quiescence.
      await tester.pump();
      return;
    }
  }
  throw StateError('Native Bots driver did not complete $name');
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  if (!const bool.fromEnvironment('BOTS_NATIVE_INPUT')) {
    throw StateError('Use scripts/test_native_bots.py on an owned emulator.');
  }
  for (final brightness in [Brightness.dark, Brightness.light]) {
    for (final large in [false, true]) {
      final label = '${brightness.name}-${large ? 'large' : 'normal'}';
      testWidgets('Android Bots $label', (tester) async {
        final priorErrorHandler = FlutterError.onError;
        FlutterError.onError = (details) {
          // Preserve the originating stack before the polling helper consumes
          // the exception and reports which native control was being awaited.
          debugPrintSynchronously(
            'Native Bots framework error: ${details.exceptionAsString()}\n'
            '${details.stack}',
          );
          priorErrorHandler?.call(details);
        };
        addTearDown(() => FlutterError.onError = priorErrorHandler);
        await _native(tester, '$label-configure', action: 'configure');
        final metricsDeadline = DateTime.now().add(const Duration(seconds: 10));
        while (((tester.view.physicalSize.width /
                            tester.view.devicePixelRatio) -
                        (large ? 320 : 390))
                    .abs() >
                1 &&
            DateTime.now().isBefore(metricsDeadline)) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        SharedPreferences.setMockInitialValues({});
        final prefs = await SharedPreferences.getInstance();
        final preferences = AppPreferences(prefs);
        final browser = ProfileBrowserFixture();
        // DrawerVersions owns its own production HTTP adapter, independently of
        // the injected chat/Bots repositories. Keep those reads on this owned
        // loopback endpoint, with unexpected transport requests failing the test.
        final unexpectedReads = <String>[];
        final versionReads = <String>{};
        final dashboard = await HttpServer.bind(
          InternetAddress.loopbackIPv4,
          0,
        );
        dashboard.listen((request) async {
          final path = request.uri.path;
          final query = request.uri.queryParameters;
          final scopedRead =
              query['profile'] == 'default' &&
              (path == '/api/hermes/update/check'
                  ? query.length == 2 && query['force'] == 'true'
                  : query.length == 1);
          if (request.method != 'GET' ||
              (path == '/' ? query.isNotEmpty : !scopedRead)) {
            unexpectedReads.add('${request.method} ${request.uri}');
            request.response.statusCode = HttpStatus.badRequest;
          } else if (path == '/' && query.isEmpty) {
            request.response.write(
              'window.__HERMES_SESSION_TOKEN__="native-bots-fixture";',
            );
          } else if (request.headers.value('X-Hermes-Session-Token') !=
              'native-bots-fixture') {
            unexpectedReads.add('Unauthenticated ${request.uri}');
            request.response.statusCode = HttpStatus.unauthorized;
          } else {
            final body = switch (path) {
              '/api/health' => {'ok': true, 'version': '1.2.3'},
              '/api/profiles' => {
                'profiles': [
                  {'name': 'default', 'is_default': true},
                ],
              },
              '/api/hermes/update/check' => {
                'current_version': '1.2.3',
                'update_available': false,
                'can_apply': false,
              },
              _ => null,
            };
            if (body == null) {
              unexpectedReads.add('${request.method} ${request.uri}');
              request.response.statusCode = HttpStatus.notFound;
            } else {
              versionReads.add(path);
              request.response.headers.contentType = ContentType.json;
              request.response.write(jsonEncode(body));
            }
          }
          await request.response.close();
        });
        addTearDown(() async {
          await dashboard.close(force: true);
          expect(unexpectedReads, isEmpty);
        });
        final controller = ProfileWorkspaceController(
          access: ConnectionAccess(
            connection: SavedConnection(
              id: 'host',
              label: 'Home server',
              host: InternetAddress.loopbackIPv4.address,
              port: 1,
              dashboardPortOverride: dashboard.port,
              apiKey: '',
            ),
            dashboardOAuth: null,
          ),
          connectionIdentity: 'instance-1',
          preferences: prefs,
          appPreferences: preferences,
          gatewayFactory: browser.gateway,
        );
        final administration = AdministrationFixture('Home server');
        final fixture = BotsFixture(server: administration.server);
        final groupUploads = <String, Map<String, dynamic>>{};
        final groupBytes = <String, String>{};
        final retryHeld = Completer<void>();
        var historyUnavailable = false;
        fixture.commandHook = (_, method, params) async {
          if (method == 'groups.attachment.upload') {
            final id =
                'att_${(groupUploads.length + 1).toRadixString(16).padLeft(32, '0')}';
            final data = params['data_base64'] as String;
            final manifest = <String, dynamic>{
              'attachment_id': id,
              'kind': params['kind'],
              'name': params['name'],
              'mime': params['mime'],
              'size': base64Decode(data).length,
            };
            groupUploads[id] = manifest;
            groupBytes[id] = data;
            return {...manifest, 'state': 'uncommitted'};
          }
          if (method == 'groups.retry') await retryHeld.future;
          return null;
        };
        fixture.readHook = (_, method, params) async {
          if (method == 'groups.log' && historyUnavailable) {
            throw StateError('History unavailable');
          }
          if (method == 'groups.attachment.download') {
            final id = params['attachment_id'] as String;
            return {
              ...groupUploads[id]!,
              'event_id': params['event_id'],
              'data_base64': groupBytes[id],
            };
          }
          return null;
        };

        fixture.profiles.first['name'] = 'personal';
        fixture.profiles.first['display_name'] = 'personal';
        fixture.profiles.first['canonical_session']['id'] = 'pinned';
        fixture.profiles.first['canonical_session']['resolved_id'] = 'pinned';
        addTearDown(() async {
          await tester.pumpWidget(const SizedBox());
          await tester.pump();
          controller.dispose();
          preferences.dispose();
          administration.server.close();
        });
        await controller.initialize();
        await tester.pumpWidget(
          MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: wingTheme(brightness),
            home: ProfileWorkspaceScreen(
              controller: controller,
              createBotsSession: () =>
                  BotsSession((_) async => [fixture.repository]),
            ),
          ),
        );
        Future<void> until(bool Function() ready, String outcome) async {
          final deadline = DateTime.now().add(const Duration(seconds: 10));
          do {
            await tester.pump(const Duration(milliseconds: 50));
            expect(tester.takeException(), isNull, reason: outcome);
            if (ready()) return;
          } while (DateTime.now().isBefore(deadline));
          fail('Timed out waiting for $outcome');
        }

        bool visible(Finder finder) =>
            finder.hitTestable().evaluate().isNotEmpty;
        final search = find.byKey(const ValueKey('bots-search'));
        // Native search keeps the query in an EditableText. Match the roster
        // label itself so opening a result cannot target the search editor.
        Finder rosterTitle(String title) => find.descendant(
          of: find.byType(BotsContent),
          matching: find.byWidgetPredicate(
            (widget) => widget is Text && widget.data == title,
          ),
        );
        final atlas = rosterTitle('Atlas');
        Future<void> roster() => until(
          () =>
              visible(search) && find.byType(BotsContent).evaluate().isNotEmpty,
          'the usable Bots roster',
        );
        Future<void> keyboardClosed() => until(
          () => tester.view.viewInsets.bottom == 0,
          'the Android keyboard to close',
        );

        await until(
          () => visible(find.byTooltip('Open navigation menu')),
          'the workspace navigation control',
        );
        final media = MediaQuery.of(
          tester.element(find.byType(ProfileWorkspaceScreen)),
        );
        expect(
          media.size.width,
          inInclusiveRange(large ? 319 : 389, large ? 321 : 391),
        );
        if (large) {
          expect(media.textScaler.scale(16), greaterThan(24));
        } else {
          expect(media.textScaler.scale(16), inInclusiveRange(15, 17));
        }
        await tester.tap(find.byTooltip('Open navigation menu'));
        final botsNav = find.byKey(const ValueKey('nav-bots'));
        await until(() => visible(botsNav), 'the Bots navigation entry');
        await until(
          () =>
              find.text('v1.2.3').evaluate().isNotEmpty &&
              versionReads.containsAll({
                '/api/health',
                '/api/profiles',
                '/api/hermes/update/check',
              }),
          'the drawer version from the owned dashboard',
        );
        await tester.ensureVisible(botsNav);
        await tester.tap(botsNav.hitTestable());
        await roster();
        await until(() => visible(atlas), 'the loaded Atlas bot');
        await _native(tester, '$label-roster');

        await tester.tap(search);
        await _native(
          tester,
          '$label-search',
          action: 'type',
          text: 'Atlas',
          keyboard: true,
        );
        await until(
          () =>
              tester.widget<TextField>(search).controller!.text == 'Atlas' &&
              tester.view.viewInsets.bottom > 0,
          'native search input with the Android keyboard open',
        );
        expect(tester.widget<TextField>(search).controller!.text, 'Atlas');
        expect(tester.view.viewInsets.bottom, greaterThan(0));
        await _native(tester, '$label-search-hide', action: 'hide-keyboard');
        await keyboardClosed();
        expect(tester.view.viewInsets.bottom, 0);
        await until(() => visible(atlas), 'the filtered Atlas bot result');
        await tester.tap(atlas.hitTestable());
        await until(
          () => visible(find.byKey(const ValueKey('profile-message-composer'))),
          'the canonical bot conversation',
        );
        expect(controller.current!.chat!.key.sessionId, 'pinned');
        await until(
          () =>
              controller.current!.chat!.title == 'Plan the Android workspace' &&
              !controller.current!.chat!.runtime.opening,
          'the canonical bot session metadata and history',
        );
        await _native(tester, '$label-chat-back', action: 'back');
        await roster();
        expect(find.byType(BotsContent), findsOneWidget);
        expect(tester.widget<TextField>(search).controller!.text, 'Atlas');

        Future<void> edit(String title) async {
          await tester.tap(find.byTooltip('Edit name & appearance for $title'));
          await until(
            () => visible(find.widgetWithText(TextField, 'Bot name')),
            'the bot appearance editor',
          );
        }

        await edit('Atlas');
        expect(find.byType(BotProfileEditor), findsOneWidget);
        await _native(tester, '$label-avatar-editor');
        final name = find.widgetWithText(TextField, 'Bot name');
        await tester.tap(name);
        await _native(
          tester,
          '$label-name',
          action: 'append',
          text: ' Native',
          keyboard: true,
        );
        await until(
          () =>
              tester.widget<TextField>(name).controller!.text ==
                  'Atlas Native' &&
              tester.view.viewInsets.bottom > 0,
          'native name input with the Android keyboard open',
        );
        expect(tester.widget<TextField>(name).controller!.text, 'Atlas Native');
        expect(tester.view.viewInsets.bottom, greaterThan(0));
        await _native(tester, '$label-name-hide', action: 'hide-keyboard');
        await keyboardClosed();
        expect(tester.view.viewInsets.bottom, 0);
        expect(find.byTooltip('Save appearance'), findsNothing);
        await _native(tester, '$label-name-autosave-back', action: 'back');
        await roster();
        expect(find.byType(BotProfileEditor), findsNothing);
        expect(
          fixture.profiles.first['ui_meta']['hermes-bots']['title'],
          'Atlas Native',
        );
        await tester.tap(find.byTooltip('Clear search'));
        await until(
          () =>
              tester.widget<TextField>(search).controller!.text.isEmpty &&
              visible(
                find.byTooltip('Edit name & appearance for Atlas Native'),
              ),
          'the renamed bot after clearing the search',
        );
        await edit('Atlas Native');
        await tester.scrollUntilVisible(
          find.byTooltip('Upload avatar'),
          200,
          scrollable: find
              .descendant(
                of: find.byType(BotProfileEditor),
                matching: find.byType(Scrollable),
              )
              .first,
        );
        await _native(tester, '$label-editor-bottom');
        await tester.tap(find.byTooltip('Upload avatar'));
        // The picker suspends Flutter rendering. Let Android cancel it before
        // pumping the restored editor, rather than waiting for background frames.
        await _native(tester, '$label-picker-cancel', action: 'picker-cancel');
        await until(
          () => visible(find.byTooltip('Upload avatar')),
          'the restored editor after cancelling the Android picker',
        );
        expect(find.byType(BotProfileEditor), findsOneWidget);
        expect(
          fixture.commands.where((call) => call.$2 == 'profiles.set_asset'),
          isEmpty,
        );
        await tester.ensureVisible(find.byTooltip('Color 1'));
        await until(
          () => visible(find.byTooltip('Color 1')),
          'the color control',
        );
        await tester.tap(find.byTooltip('Color 1'));
        await _native(tester, '$label-color-autosave-back', action: 'back');
        await roster();
        expect(find.text('Discard edits?'), findsNothing);
        expect(
          fixture.profiles.first['ui_meta']['hermes-bots']['color'],
          isNot('#65c7bc'),
        );
        expect(find.byType(BotsContent), findsOneWidget);
        await tester.tap(find.byTooltip('Actions for Atlas Native'));
        await until(
          () => visible(find.byKey(const ValueKey('bot-menu-settings'))),
          'the bot action menu',
        );
        expect(find.byKey(const ValueKey('bot-menu-edit')), findsNothing);
        await tester.tap(find.byKey(const ValueKey('bot-menu-settings')));
        await until(
          () => visible(find.text('Role & instructions')),
          'bot settings',
        );
        expect(find.text('Role & instructions'), findsOneWidget);
        await _native(tester, '$label-settings');
        await _native(tester, '$label-settings-back', action: 'back');
        await roster();

        await tester.tap(
          find
              .descendant(
                of: find.byType(BotsContent),
                matching: find.byTooltip('Create bot'),
              )
              .hitTestable(),
        );
        await until(
          () => visible(find.widgetWithText(TextField, 'Profile name')),
          'the new bot form',
        );
        await _native(
          tester,
          '$label-new-name',
          action: 'type',
          text: 'native-bot',
          keyboard: true,
        );
        await until(
          () =>
              tester
                      .widget<TextField>(
                        find.widgetWithText(TextField, 'Profile name'),
                      )
                      .controller!
                      .text ==
                  'native-bot' &&
              tester.view.viewInsets.bottom > 0,
          'native new-bot input with the Android keyboard open',
        );
        expect(
          tester
              .widget<TextField>(find.widgetWithText(TextField, 'Profile name'))
              .controller!
              .text,
          'native-bot',
        );
        expect(tester.view.viewInsets.bottom, greaterThan(0));
        await _native(tester, '$label-new-hide', action: 'hide-keyboard');
        await keyboardClosed();
        expect(tester.view.viewInsets.bottom, 0);
        await _native(tester, '$label-create');
        await tester.tap(
          find
              .descendant(
                of: find.byType(BotsCreateScreen),
                matching: find.byTooltip('Create bot'),
              )
              .hitTestable(),
        );
        await roster();
        expect(
          fixture.commands.where((c) => c.$2 == 'profiles.create'),
          hasLength(1),
        );

        await tester.tap(find.widgetWithText(Tab, 'Groups'));
        await until(
          () => visible(rosterTitle('Research team')),
          'the group roster',
        );
        await tester.tap(rosterTitle('Research team').hitTestable());
        final groupComposer = find.byKey(
          const ValueKey('group-message-composer'),
        );
        await until(() => visible(groupComposer), 'the group conversation');
        await tester.tap(groupComposer);
        await _native(
          tester,
          '$label-message',
          action: 'type',
          text: 'Review the plan',
          keyboard: true,
        );
        await until(
          () =>
              tester.widget<TextField>(groupComposer).controller!.text ==
                  'Review the plan' &&
              tester.view.viewInsets.bottom > 0,
          'native group message input with the Android keyboard open',
        );
        expect(tester.view.viewInsets.bottom, greaterThan(0));
        fixture.sendLost = true;
        historyUnavailable = true;
        await tester.tap(find.byTooltip('Send group message'));
        await until(
          () =>
              visible(find.byTooltip('Retry same message')) &&
              tester.widget<TextField>(groupComposer).readOnly,
          'the retry control for the uncertain group message',
        );
        expect(find.byTooltip('Retry same message'), findsOneWidget);
        expect(tester.widget<TextField>(groupComposer).readOnly, true);
        // Making the pending message read-only dismisses the IME itself.
        // Wait for that transition before native capture; Back during stale
        // Flutter insets can otherwise pop the group after Android hid it.
        await keyboardClosed();
        await _native(tester, '$label-group-hide', keyboard: false);
        expect(tester.view.viewInsets.bottom, 0);
        await _native(tester, '$label-retry');
        historyUnavailable = false;
        await tester.tap(find.byTooltip('Retry same message'));
        await until(
          () =>
              fixture.events.length == 1 &&
              !tester.widget<TextField>(groupComposer).readOnly &&
              tester
                  .widget<TextField>(groupComposer)
                  .controller!
                  .text
                  .isEmpty &&
              find.byTooltip('Retry same message').evaluate().isEmpty,
          'one accepted group message and an editable empty composer',
        );
        expect(fixture.events, hasLength(1));

        fixture.pending.add({
          'kind': 'retry',
          'task_id': 'native-retry',
          'member_id': 'atlas',
          'execution_generation': 7,
        });
        await tester.tap(find.byTooltip('Group options'));
        await tester.pump(const Duration(milliseconds: 300));
        await tester.tap(find.text('Refresh group'));
        await until(
          () => visible(find.byTooltip('Retry group attempt')),
          'exact group retry action',
        );
        await tester.tap(find.byTooltip('Retry group attempt'));
        await tester.pump(const Duration(milliseconds: 100));
        await _native(tester, '$label-exact-retry-pending');
        expect(fixture.commands.last.$2, 'groups.retry');
        expect(fixture.commands.last.$3, {
          'room_id': 'room-1',
          'task_id': 'native-retry',
          'member_id': 'atlas',
          'execution_generation': 7,
        });
        retryHeld.complete();
        await until(
          () => find.byTooltip('Retry group attempt').evaluate().isEmpty,
          'accepted exact group retry',
        );
        expect(
          fixture.commands.where((call) => call.$2 == 'groups.stop'),
          isEmpty,
        );
        await tester.tap(find.byTooltip('Attach file'));
        await tester.pump(const Duration(milliseconds: 300));
        await tester.tap(find.text('Files'));
        await _native(
          tester,
          '$label-pick-group-file',
          action: 'pick-group-file',
        );
        await until(
          () =>
              groupUploads.isNotEmpty &&
              visible(find.text('wing-group-notes.txt')),
          'native picked file uploaded into group draft',
        );
        await _native(tester, '$label-group-file-ready');
        await tester.tap(find.byTooltip('Send group message'));
        await until(
          () =>
              fixture.events.length == 2 &&
              visible(find.byTooltip('Download wing-group-notes.txt')),
          'attachment-only group message and exact download control',
        );
        final manifest = groupUploads.values.single;
        expect((fixture.events.last['payload'] as Map)['attachments'], [
          manifest,
        ]);
        await _native(tester, '$label-group-file-sent');
        await tester.tap(find.byTooltip('Download wing-group-notes.txt'));
        await _native(
          tester,
          '$label-group-save-cancel',
          action: 'picker-cancel',
        );
        await until(
          () => visible(find.byTooltip('Download wing-group-notes.txt')),
          'cancelled native save leaves group attachment readable',
        );

        // Exercise the new group controls after the existing attachment journey
        // so their durable events do not change its exact message-count checks.
        final state = await fixture.read('default', 'groups.state', {
          'room_id': 'room-1',
        });
        var contextGate = Completer<void>();
        final discardGate = Completer<void>();
        final continueGate = Completer<void>();
        var rejectContext = true;
        Map<String, dynamic> appendGroupEvent(
          String id,
          String kind,
          Map<String, dynamic> payload,
        ) {
          final event = <String, dynamic>{
            'room_id': 'room-1',
            'seq': (fixture.events.last['seq'] as int) + 1,
            'event_id': id,
            'kind': kind,
            'actor': {'kind': 'gateway', 'id': 'gateway-1'},
            'payload': payload,
            'created_at': 1791756000.0,
          };
          fixture.events.add(event);
          return event;
        }

        fixture.readHook = (_, method, _) async => method == 'groups.state'
            ? {
                ...state,
                'room': {
                  ...fixture.room,
                  'latest_seq': fixture.events.last['seq'],
                },
              }
            : null;
        fixture.commandHook = (_, method, params) async {
          if (method == 'groups.context') {
            await contextGate.future;
            if (rejectContext) throw StateError('Save refused');
            state['context'] = {
              for (final key in [
                'purpose',
                'notes',
                'routing',
                'lead_member_id',
              ])
                key: params[key],
            };
            final event = appendGroupEvent(
              params['event_id'] as String,
              'room.context_set',
              state['context'] as Map<String, dynamic>,
            );
            return {'context': state['context'], 'event': event};
          }
          if (method == 'groups.discard') {
            await discardGate.future;
            fixture.pending.clear();
            return {
              'discarded': true,
              'task': {'room_id': 'room-1', 'task_id': params['task_id']},
            };
          }
          if (method == 'groups.continue') {
            await continueGate.future;
            return {
              'continued': true,
              'event': appendGroupEvent('native-continued', 'room.continued', {
                'discussion_event_id': params['discussion_event_id'],
                'thread_id': 'native-discussion-thread',
                'grant': 1,
              }),
            };
          }
          throw StateError('Unexpected group control $method');
        };

        await tester.tap(find.byTooltip('Group options'));
        await tester.pump(const Duration(milliseconds: 300));
        await tester.tap(find.text('Shared settings'));
        final purpose = find.widgetWithText(TextField, 'Purpose');
        await until(() => visible(purpose), 'the shared group settings');
        await tester.tap(purpose);
        await _native(
          tester,
          '$label-group-purpose',
          action: 'type',
          text: 'Review the release together',
          keyboard: true,
        );
        await until(
          () =>
              tester.widget<TextField>(purpose).controller!.text ==
              'Review the release together',
          'native group purpose input',
        );
        await _native(tester, '$label-group-purpose-back', action: 'back');
        await keyboardClosed();
        await tester.tap(find.byTooltip('Save shared settings'));
        await until(
          () => tester
              .widget<StudioFormActions>(find.byType(StudioFormActions))
              .busy,
          'held group settings save feedback',
        );
        await _native(tester, '$label-group-settings-pending', keyboard: false);
        contextGate.complete();
        await until(
          () => !tester
              .widget<StudioFormActions>(find.byType(StudioFormActions))
              .busy,
          'failed settings save retaining the editor',
        );
        expect(
          tester.widget<TextField>(purpose).controller!.text,
          'Review the release together',
        );
        expect(
          find.descendant(
            of: find.byType(BotGroupContextSheet),
            matching: find.text(
              'Shared settings could not be confirmed. Review your draft and retry.',
            ),
          ),
          findsOneWidget,
        );
        final firstContext = fixture.commands.last.$3;
        rejectContext = false;
        contextGate = Completer<void>();
        await tester.tap(find.byTooltip('Save shared settings'));
        await until(
          () =>
              fixture.commands
                  .where((call) => call.$2 == 'groups.context')
                  .length ==
              2,
          'retry of the exact settings save',
        );
        expect(fixture.commands.last.$3, firstContext);
        contextGate.complete();
        await until(
          () => purpose.evaluate().isEmpty,
          'confirmed settings save closes the editor',
        );
        expect(
          (state['context'] as Map)['purpose'],
          'Review the release together',
        );

        fixture.pending.add({
          'kind': 'discard',
          'task_id': 'native-unknown',
          'member_id': 'atlas',
          'execution_generation': 9,
        });
        appendGroupEvent('native-discussion', 'message.user', {
          'text': 'Continue this bounded discussion',
          'thread_id': 'native-discussion-thread',
        });
        appendGroupEvent('native-bounded', 'room.activity', {
          'discussion_event_id': 'native-discussion',
          'thread_id': 'native-discussion-thread',
          'status': 'bounded',
        });
        await tester.tap(find.byTooltip('Group options'));
        await tester.pump(const Duration(milliseconds: 300));
        await tester.tap(find.text('Refresh group'));
        // Returning from the Android picker preserves the earlier attachment.
        // Follow the ordinary latest control to the newly received discussion.
        final latest = find.byKey(const ValueKey('jump-to-latest'));
        await until(
          () =>
              visible(latest) &&
              find.byTooltip('Refreshing group').evaluate().isEmpty,
          'settled group refresh and latest navigation',
        );
        final latestRect = tester.getRect(latest);
        final screen =
            Offset.zero &
            (tester.view.physicalSize / tester.view.devicePixelRatio);
        expect(latestRect.width, greaterThanOrEqualTo(48));
        expect(latestRect.height, greaterThanOrEqualTo(48));
        expect(screen.intersect(latestRect), latestRect);
        await tester.tap(latest.hitTestable());
        final discard = find.byTooltip('Discard unknown group attempt');
        await until(
          () => discard.evaluate().isNotEmpty,
          'exact Discard control',
        );
        await tester.ensureVisible(discard);
        await tester.pump();
        await tester.tap(discard.hitTestable());
        await until(
          () => visible(find.byTooltip('Discard unknown attempt')),
          'unknown-outcome confirmation',
        );
        expect(find.text('Discard unknown attempt?'), findsOneWidget);
        await tester.tap(find.byTooltip('Discard unknown attempt'));
        await until(
          () => find.byType(StudioLoading).evaluate().isNotEmpty,
          'held Discard feedback',
        );
        await _native(tester, '$label-group-discard-pending');
        expect(fixture.commands.last.$2, 'groups.discard');
        expect(fixture.commands.last.$3, {
          'room_id': 'room-1',
          'task_id': 'native-unknown',
          'member_id': 'atlas',
          'execution_generation': 9,
        });
        discardGate.complete();
        await until(() => discard.evaluate().isEmpty, 'settled exact Discard');
        final continuation = find.byTooltip('Continue discussion');
        await until(
          () => continuation.evaluate().isNotEmpty,
          'bounded Continue control',
        );
        await tester.ensureVisible(continuation);
        await tester.pump();
        await tester.tap(continuation.hitTestable());
        await until(
          () => find.byType(StudioLoading).evaluate().isNotEmpty,
          'held Continue feedback',
        );
        await _native(tester, '$label-group-continue-pending');
        expect(fixture.commands.last.$2, 'groups.continue');
        expect(fixture.commands.last.$3, {
          'room_id': 'room-1',
          'discussion_event_id': 'native-discussion',
        });
        continueGate.complete();
        await until(
          () => continuation.evaluate().isEmpty,
          'settled bounded Continue',
        );
        await _native(tester, '$label-group-controls-settled');
        await _native(tester, '$label-group-back', action: 'back');
        await until(
          () =>
              find.byType(BotGroupScreen).evaluate().isEmpty ||
              tester.view.viewInsets.bottom == 0,
          'Android Back to dismiss the keyboard or leave the group',
        );
        // Successful retry makes the focused composer editable again. Android
        // Back first dismisses its restored IME, then leaves the room.
        if (find.byType(BotGroupScreen).evaluate().isNotEmpty) {
          expect(tester.view.viewInsets.bottom, 0);
          await _native(tester, '$label-group-route-back', action: 'back');
        }
        await roster();
        expect(find.byType(BotsContent), findsOneWidget);
        expect(find.widgetWithText(Tab, 'Groups'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await _native(tester, '$label-complete');
      });
    }
  }
}
