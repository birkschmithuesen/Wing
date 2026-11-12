import 'package:wing/core/services/app_preferences.dart';
import 'package:wing/core/services/bots_session.dart';
import 'package:wing/core/services/connection_access.dart';
import 'dart:io';
import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wing/core/screens/profile_workspace_screen.dart';
import 'package:wing/core/services/connection_manager.dart';
import 'package:wing/core/services/profile_workspace_controller.dart';
import 'package:wing/core/theme/wing_theme.dart';
import 'package:wing/core/widgets/slash_command_suggestions.dart';

import '../test/slash_commands_test.dart' show CommandHost;
import '../test/helpers/journey_controls.dart' show tapJourneyControl;

/// Native input/screenshot checkpoints for a host driving the disposable emulator.
Future<void> _nativeCheckpoint(WidgetTester tester, String name) async {
  if (!const bool.fromEnvironment('SLASH_NATIVE_INPUT')) return;
  final directory = Directory.systemTemp.path;
  final token = '$name-${DateTime.now().microsecondsSinceEpoch}';
  await File(
    '$directory/wing-slash-stage.json',
  ).writeAsString(jsonEncode({'name': name, 'token': token}));
  final receipt = File('$directory/wing-slash-ack');
  final deadline = DateTime.now().add(const Duration(seconds: 30));
  while (DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 100));
    if (await receipt.exists() && await receipt.readAsString() == token) return;
  }
  throw StateError('Native Android driver did not complete $name');
}

/// Production Android composer with a strict stock completion-contract fixture.
/// No live server or model requests. Run only on a disposable emulator.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const captureKey = ValueKey('slash-capture');

  for (final brightness in [Brightness.dark, Brightness.light]) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('/app selection ${brightness.name} $scale', (tester) async {
        await _nativeCheckpoint(tester, '${brightness.name}-$scale-configure');
        SharedPreferences.setMockInitialValues({});
        final host = CommandHost()
          ..warning =
              'slash command /handoff unavailable — name taken by built-in; use /skill handoff; '
              'slash command /plan unavailable — name taken by built-in; use /skill plan';
        final fixturePreferences = await SharedPreferences.getInstance();
        final appPreferences = AppPreferences(fixturePreferences);
        addTearDown(appPreferences.dispose);
        final controller = ProfileWorkspaceController(
          appPreferences: appPreferences,
          connectionIdentity: 'native-slash-completion',
          access: ConnectionAccess(
            connection: SavedConnection(
              id: 'native-slash-completion',
              label: 'Completion QA',
              host: 'unused',
              port: 1,
              apiKey: '',
            ),
            dashboardOAuth: null,
          ),
          preferences: fixturePreferences,
          gatewayFactory: host.gateway,
        );
        addTearDown(controller.dispose);
        await controller.initialize();
        final chat = await controller.createChat(canDispatch: () => true);
        await tester.pumpWidget(
          RepaintBoundary(
            key: captureKey,
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: wingTheme(brightness),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: TextScaler.linear(scale)),
                child: child!,
              ),
              home: ProfileWorkspaceScreen(
                controller: controller,
                createBotsSession: () => BotsSession((_) async => const []),
              ),
            ),
          ),
        );
        Future<void> frames() async {
          for (var i = 0; i < 8; i++) {
            await tester.pump(const Duration(milliseconds: 100));
          }
        }

        Future<void> reveal(Finder item) async {
          await frames();
          final list = find.descendant(
            of: find.byType(SlashCommandSuggestions),
            matching: find.byType(ListView),
          );
          final trace = <Map<String, Object?>>[];
          Map<String, Object?> observe() {
            List<Map<String, Object?>> boxes(Finder finder) => [
              for (final element in finder.evaluate())
                if (element.findRenderObject() case final RenderBox box
                    when box.attached && box.hasSize)
                  {
                    'origin': box.localToGlobal(Offset.zero).toString(),
                    'size': box.size.toString(),
                  },
            ];
            final scrollables = <Element>{
              ...find
                  .descendant(of: list, matching: find.byType(Scrollable))
                  .evaluate(),
              ...find
                  .ancestor(of: list, matching: find.byType(Scrollable))
                  .evaluate(),
            };
            return {
              'itemMounted': item.evaluate().length,
              'itemHitTestable': item.hitTestable().evaluate().length,
              'itemBoxes': boxes(item),
              'listBoxes': boxes(list),
              'outerBoxes': boxes(
                find.ancestor(
                  of: list,
                  matching: find.byType(SingleChildScrollView),
                ),
              ),
              'scrolls': [
                for (final element in scrollables)
                  if ((element as StatefulElement).state
                      case final ScrollableState state)
                    {
                      'axis': state.position.axisDirection.name,
                      'pixels': state.position.pixels,
                      'min': state.position.minScrollExtent,
                      'max': state.position.maxScrollExtent,
                      'viewport': state.position.viewportDimension,
                    },
              ],
              'draft': chat.composer.observation.displayedText,
              'keyboardBottom': tester.view.viewInsets.bottom,
              'physicalSize': tester.view.physicalSize.toString(),
              'pixelRatio': tester.view.devicePixelRatio,
            };
          }

          for (
            var i = 0;
            i < 15 && item.hitTestable().evaluate().isEmpty;
            i++
          ) {
            final viewport = find
                .ancestor(
                  of: list,
                  matching: find.byType(SingleChildScrollView),
                )
                .first;
            final visible = tester
                .getRect(list)
                .intersect(tester.getRect(viewport));
            final inner = tester
                .state<ScrollableState>(
                  find.descendant(of: list, matching: find.byType(Scrollable)),
                )
                .position;
            // At the list's end, its final item can still be clipped by the
            // outer composer viewport. Drag the visible suggestion header to
            // scroll that outer surface, as a user would, rather than sending
            // another gesture to the already exhausted inner list.
            final outerRect = tester.getRect(viewport);
            final header = Rect.fromLTRB(
              outerRect.left,
              outerRect.top,
              outerRect.right,
              tester.getRect(list).top,
            );
            final dragStart = inner.extentAfter == 0 && header.height > 0
                ? header.center
                : visible.center;
            trace.add({...observe(), 'dragStart': dragStart.toString()});
            await tester.dragFrom(dragStart, const Offset(0, -80));
            await frames();
          }
          if (item.hitTestable().evaluate().isEmpty) trace.add(observe());
          expect(
            item.hitTestable(),
            findsOneWidget,
            reason: trace.isEmpty ? null : jsonEncode(trace),
          );
        }

        await frames();
        final composer = find.byKey(const Key('profile-message-composer'));
        await tester.tap(composer);
        await tester.enterText(composer, '/app');
        await frames();
        final approval = find.descendant(
          of: find.byType(SlashCommandSuggestions),
          matching: find.text('/approvals'),
        );
        await reveal(approval);
        await tester.tap(approval.hitTestable());
        await frames();
        expect(chat.composer.observation.text, '/approvals ');

        final failed = find
            .text('Could not load commands. Tap to retry.')
            .evaluate()
            .isNotEmpty;
        final name =
            'slash-${failed ? 'error' : 'fixed'}-${brightness.name}-$scale';
        final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(captureKey),
        );
        final frame = await boundary.toImage();
        final bytes = (await frame.toByteData(
          format: ui.ImageByteFormat.png,
        ))!.buffer.asUint8List();
        frame.dispose();
        final directory = await getExternalStorageDirectory();
        await File('${directory!.path}/$name.png').writeAsBytes(bytes);
        expect(
          find.text('Could not load commands. Tap to retry.'),
          findsNothing,
        );
        expect(
          host.commandCalls
              .singleWhere((call) => call.$1 == 'complete.slash')
              .$2,
          {'session_id': chat.runtime.runtimeId, 'text': '/approvals '},
        );
        expect(
          host.commandCalls.where((call) => call.$1 == 'prompt.submit'),
          isEmpty,
        );
        await reveal(find.text('smart'));
        await tester.tap(find.text('smart').hitTestable());
        await frames();
        expect(chat.composer.observation.text, '/approvals smart ');
        expect(
          host.commandCalls.where((call) => call.$1 == 'command.dispatch'),
          isEmpty,
        );

        // The native driver injects real Android key events into the focused
        // input connection. Without it, retain an ordinary emulator smoke case.
        await controller.updateDraft(chat, '');
        await frames();
        await Scrollable.ensureVisible(tester.element(composer));
        await frames();
        await tester.tap(composer);
        await frames();
        final label = '${brightness.name}-$scale';
        if (const bool.fromEnvironment('SLASH_NATIVE_INPUT')) {
          await _nativeCheckpoint(tester, '$label-type-inline');
          await frames();
          expect(tester.view.viewInsets.bottom, greaterThan(0));
        } else {
          await tester.enterText(composer, 'Please use /a-');
        }
        await frames();
        expect(chat.composer.observation.text, 'Please use /a-');
        final skill = find.descendant(
          of: find.byType(SlashCommandSuggestions),
          matching: find.text('/a-skill'),
        );
        await reveal(skill);
        expect(
          find.descendant(
            of: find.byType(SlashCommandSuggestions),
            matching: find.text('/model'),
          ),
          findsNothing,
        );
        await _nativeCheckpoint(tester, '$label-picker-ready');
        await tester.tap(skill.hitTestable());
        await frames();
        final input = tester.widget<TextField>(composer).controller!;
        expect(input.text, 'Please use /a-skill ');
        expect(input.selection.isCollapsed, isTrue);
        expect(find.text('/a-skill'), findsNothing);
        final editable = tester.widget<EditableText>(
          find.descendant(of: composer, matching: find.byType(EditableText)),
        );
        final spans = input.buildTextSpan(
          context: tester.element(composer),
          style: editable.style,
          withComposing: true,
        );
        expect(spans.toPlainText(), input.text);
        final emphasized = spans.children!.whereType<TextSpan>().singleWhere(
          (s) => s.text == '/a-skill',
        );
        expect(emphasized.style!.fontWeight, FontWeight.w700);
        expect(
          emphasized.style!.color,
          Theme.of(tester.element(composer)).colorScheme.primary,
        );
        await _nativeCheckpoint(tester, '$label-selected');
        if (const bool.fromEnvironment('SLASH_NATIVE_INPUT')) {
          await _nativeCheckpoint(tester, '$label-type-suffix');
        } else {
          await tester.enterText(composer, '${input.text}for this task');
        }
        await frames();
        expect(
          chat.composer.observation.text,
          'Please use /a-skill for this task',
        );
        await _nativeCheckpoint(tester, '$label-suffix-ready');

        // Replace a token inside existing text and retain the suffix verbatim.
        await controller.updateDraft(chat, 'Please use /a- for this task');
        await frames();
        input.selection = const TextSelection.collapsed(offset: 14);
        await reveal(skill);
        await tester.tap(skill.hitTestable());
        await frames();
        expect(input.text, 'Please use /a-skill for this task');
        expect(input.selection.extentOffset, 19);
        if (const bool.fromEnvironment('SLASH_NATIVE_INPUT')) {
          await _nativeCheckpoint(tester, '$label-backspace');
          await frames();
          expect(input.text, 'Please use /a-skil for this task');
        }

        // Exercise compression through the actual production Send control.
        // A held preview uses the existing command admission: visible progress
        // and a retained, disabled command draft until acknowledgement. After
        // settlement the user can author a new draft without sending a prompt.
        final compression = Completer<Map<String, dynamic>>();
        host.respond = (method, params) {
          expect(method, 'session.mutate');
          expect(params['operation'], 'compress');
          expect(params['payload'], {'focus': 'here 2 --preview'});
          return compression.future;
        };
        await tester.enterText(composer, '/compress here 2 --preview');
        await frames();
        await tapJourneyControl(tester, find.byTooltip('Send'));
        for (var i = 0; i < 100 && !chat.runtime.commandRunning; i++) {
          await tester.pump(const Duration(milliseconds: 50));
        }
        await frames();
        expect(find.text('Running command…'), findsOneWidget);
        expect(find.text('Running command…').hitTestable(), findsOneWidget);
        expect(tester.widget<TextField>(composer).enabled, isFalse);
        expect(input.text, '/compress here 2 --preview');
        Future<void> captureCompression(String state) async {
          final boundary = tester.renderObject<RenderRepaintBoundary>(
            find.byKey(captureKey),
          );
          final frame = await boundary.toImage();
          final bytes = (await frame.toByteData(
            format: ui.ImageByteFormat.png,
          ))!.buffer.asUint8List();
          frame.dispose();
          await File(
            '${directory.path}/compression-$state-$label.png',
          ).writeAsBytes(bytes);
        }

        await captureCompression('pending');
        compression.complete({
          'session_id': chat.runtime.runtimeId,
          'operation': 'compress',
          'status': 'preview',
          'lines': ['Compression preview: keep the newest 2 messages.'],
          'head_count': 4,
          'tail_count': 2,
          'message_count': 6,
        });
        for (var i = 0; i < 100 && chat.runtime.commandRunning; i++) {
          await tester.pump(const Duration(milliseconds: 50));
        }
        await frames();
        expect(chat.runtime.commandRunning, isFalse);
        expect(find.text('Running command…'), findsNothing);
        expect(input.text, isEmpty);
        expect(tester.widget<TextField>(composer).enabled, isTrue);
        expect(
          host.commandCalls.where((c) => c.$1 == 'session.mutate'),
          hasLength(1),
        );
        expect(
          host.commandCalls.where((c) => c.$1 == 'command.dispatch'),
          isEmpty,
        );
        expect(
          chat.reading.messages.any(
            (m) =>
                m['content'] ==
                'Compression preview: keep the newest 2 messages.',
          ),
          isTrue,
        );
        await captureCompression('preview');
        await Scrollable.ensureVisible(tester.element(composer));
        await tester.tap(composer.hitTestable());
        await frames();
        expect(tester.widget<TextField>(composer).focusNode!.hasFocus, isTrue);
        if (const bool.fromEnvironment('SLASH_NATIVE_INPUT')) {
          await _nativeCheckpoint(tester, '$label-type-post-compression');
        } else {
          await tester.enterText(composer, 'Keep this newer draft');
        }
        await frames();
        expect(input.text, 'Keep this newer draft');
        expect(chat.composer.observation.text, 'Keep this newer draft');
        await _nativeCheckpoint(tester, '$label-post-compression-ready');
        expect(
          host.commandCalls.where((c) => c.$1 == 'prompt.submit'),
          isEmpty,
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      });
    }
  }
}
