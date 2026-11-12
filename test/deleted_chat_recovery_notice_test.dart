import 'package:wing/core/widgets/studio_loading.dart';
import 'package:wing/core/models/profile_session_key.dart';
import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/models/hermes_profile.dart';
import 'package:wing/core/services/profile_workspace_controller.dart';
import 'package:wing/core/theme/wing_theme.dart';
import 'package:wing/core/widgets/deleted_chat_recovery_notice.dart';

const _capture = bool.fromEnvironment('CAPTURE_DELETED_RECOVERY');
const _captureKey = ValueKey('deleted-recovery-capture');
const _reviewKey = ValueKey('deleted-chat-review');
const _listKey = ValueKey('deleted-chat-recovery-list');

DeletedDraftCleanupEntry _entry(
  String id, {
  String? title,
  String detail =
      'Deletion is unconfirmed. Local work is kept until the chat can be checked.',
  String? error,
  bool busy = false,
  List<DeletedDraftCleanupAction> actions = const [],
}) => DeletedDraftCleanupEntry(
  key: ProfileSessionKey(
    WorkspaceScope(
      connectionId: 'recovery-render-fixture',
      connectionIdentity: 'recovery-render-owner',
      profileName: 'default',
    ),
    id,
  ),
  title: title ?? 'Chat $id',
  profile: 'default',
  identification: 'Chat $id',
  detail: detail,
  error: error,
  busy: busy,
  actions: actions,
);

DeletedDraftCleanupPresentation _state(
  List<DeletedDraftCleanupEntry> entries,
) => DeletedDraftCleanupPresentation(
  summary:
      '${entries.length} ${entries.length == 1 ? 'chat needs' : 'chats need'} recovery',
  entries: entries,
);

Future<void> _render(
  WidgetTester tester,
  ValueNotifier<DeletedDraftCleanupPresentation> state, {
  Brightness brightness = Brightness.light,
  double scale = 1,
  Size size = const Size(390, 844),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  // Unmount consumers before disposing the passive test owner.
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    state.dispose();
  });
  await tester.pumpWidget(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: wingTheme(brightness),
      builder: (context, child) => RepaintBoundary(
        key: _captureKey,
        child: MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: TextScaler.linear(scale),
            disableAnimations: true,
          ),
          child: child!,
        ),
      ),
      home: Scaffold(
        appBar: AppBar(title: const Text('Chats')),
        body: Column(
          children: [
            DeletedChatRecoveryNotice(presentation: state),
            const Expanded(child: Center(child: Text('Retained chat list'))),
          ],
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _snapshot(WidgetTester tester, String name) async {
  if (!_capture) return;
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(_captureKey),
  );
  await tester.runAsync(() async {
    final image = await boundary.toImage();
    try {
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      final file = File('build/deleted-recovery-review/$name.png');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes!.buffer.asUint8List());
    } finally {
      image.dispose();
    }
  });
}

Future<void> _open(WidgetTester tester) async {
  await tester.tap(find.byKey(_reviewKey));
  await tester.pumpAndSettle();
}

Future<void> _reach(
  WidgetTester tester,
  Finder target, {
  double delta = 120,
}) async {
  final scrollable = find.descendant(
    of: find.byKey(_listKey),
    matching: find.byType(Scrollable),
  );
  // Sliver cache children can exist below the viewport. Require actual pointer
  // reachability, then render the final ensureVisible scroll offset.
  await tester.scrollUntilVisible(
    target.hitTestable(),
    delta,
    scrollable: scrollable,
    maxScrolls: 100,
  );
  await tester.pumpAndSettle();
  expect(target.hitTestable(), findsOneWidget);
}

Finder _action(String label) => find.widgetWithText(TextButton, label);

void _minimumTarget(WidgetTester tester, Finder finder) {
  final size = tester.getSize(finder);
  expect(size.width, greaterThanOrEqualTo(48));
  expect(size.height, greaterThanOrEqualTo(48));
}

void main() {
  setUpAll(() async {
    if (!_capture) return;
    const fonts = String.fromEnvironment('CAPTURE_FONT_DIR');
    for (final font in {
      'Roboto': 'Roboto-Regular.ttf',
      'MaterialIcons': 'MaterialIcons-Regular.otf',
    }.entries) {
      await (FontLoader(font.key)..addFont(
            File(
              '$fonts/${font.value}',
            ).readAsBytes().then(ByteData.sublistView),
          ))
          .load();
    }
  });

  testWidgets('empty and summary react without changing the retained list', (
    tester,
  ) async {
    final state = ValueNotifier(const DeletedDraftCleanupPresentation.empty());
    await _render(tester, state);
    expect(find.byKey(_reviewKey), findsNothing);
    expect(find.text('Retained chat list'), findsOneWidget);
    await _snapshot(tester, 'empty');
    state.value = _state([_entry('pending')]);
    await tester.pump();
    expect(find.byKey(_reviewKey), findsOneWidget);
    _minimumTarget(tester, find.byKey(_reviewKey));
    await _open(tester);
    expect(find.text('Chat pending'), findsOneWidget);
    state.value = const DeletedDraftCleanupPresentation.empty();
    await tester.pump();
    expect(find.text('No chat deletions need attention.'), findsOneWidget);
    await _snapshot(tester, 'review-empty');
    expect(find.byKey(_reviewKey), findsNothing);
    await tester.tap(find.byTooltip('Close chat recovery'));
    await tester.pumpAndSettle();
    expect(find.text('Retained chat list'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('supplied facts and Check Keep Retry callbacks stay reactive', (
    tester,
  ) async {
    final calls = <String>[];
    final state = ValueNotifier(
      _state([
        _entry(
          'same-profile-first-long-full-identifier',
          title: 'Chat same-profile',
          error: 'Could not check this chat. Try again when connected.',
          actions: [
            DeletedDraftCleanupAction(
              label: 'Check chat',
              invoke: () => calls.add('check'),
            ),
          ],
        ),
      ]),
    );
    await _render(tester, state);
    await _open(tester);
    await _snapshot(tester, 'review-unavailable');
    expect(
      find.text('Could not check this chat. Try again when connected.'),
      findsOneWidget,
    );
    expect(_action('Keep chat'), findsNothing);
    expect(_action('Retry cleanup'), findsNothing);
    _minimumTarget(tester, _action('Check chat'));
    final identification = 'Chat same-profile-first-long-full-identifier';
    expect(find.byTooltip(identification), findsOneWidget);
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is Semantics && widget.properties.label == identification,
      ),
      findsOneWidget,
    );
    await tester.tap(_action('Check chat'));
    await tester.pump();
    expect(calls, ['check']);
    // The owner, rather than the renderer, supplies the next eligibility.
    state.value = _state([
      _entry(
        'present',
        detail: 'This chat still exists. Retained work can be restored.',
        actions: [
          DeletedDraftCleanupAction(
            label: 'Keep chat',
            invoke: () => calls.add('keep'),
          ),
        ],
      ),
    ]);
    await tester.pump();
    expect(_action('Check chat'), findsNothing);
    await _snapshot(tester, 'review-present-keep');
    _minimumTarget(tester, _action('Keep chat'));
    await tester.tap(_action('Keep chat'));
    state.value = _state([
      _entry(
        'local',
        detail: 'Chat deleted. Local draft cleanup is pending.',
        actions: [
          DeletedDraftCleanupAction(
            label: 'Retry cleanup',
            invoke: () => calls.add('retry'),
          ),
        ],
      ),
    ]);
    await tester.pump();
    await _snapshot(tester, 'review-local-retry');
    _minimumTarget(tester, _action('Retry cleanup'));
    await tester.tap(_action('Retry cleanup'));
    expect(calls, ['check', 'keep', 'retry']);
    expect(find.text('Delete'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      testWidgets(
        'phone ${brightness.name} text $scale has reachable wrapped actions',
        (tester) async {
          var checks = 0;
          final state = ValueNotifier(
            _state([
              _entry(
                'long-render-identifier',
                title:
                    'Planning a long conversation with an unusually descriptive title and retained local work',
                error:
                    'The chat could not be checked. Local work remains available for recovery.',
                actions: [
                  DeletedDraftCleanupAction(
                    label: 'Check chat',
                    invoke: () => checks++,
                  ),
                ],
              ),
              _entry(
                'busy',
                title: 'A recovery operation is still running',
                busy: true,
              ),
            ]),
          );
          await _render(
            tester,
            state,
            brightness: brightness,
            scale: scale,
            size: Size(scale == 1 ? 390 : 320, 844),
          );
          await _snapshot(tester, 'notice-${brightness.name}-${scale.toInt()}');
          await _open(tester);
          await _snapshot(tester, 'review-${brightness.name}-${scale.toInt()}');
          final headerSlot = tester.getRect(find.byType(StudioLoadingSlot));
          await _reach(tester, _action('Check chat'));
          _minimumTarget(tester, _action('Check chat'));
          await tester.tap(_action('Check chat').hitTestable());
          expect(checks, 1);
          await _reach(
            tester,
            find.text('A recovery operation is still running'),
          );
          expect(find.byType(StudioLoading), findsOneWidget);
          expect(tester.getRect(find.byType(StudioLoadingSlot)), headerSlot);
          expect(
            headerSlot.contains(
              tester.getRect(find.byType(StudioLoading)).center,
            ),
            isTrue,
          );
          await _snapshot(tester, 'busy-${brightness.name}-${scale.toInt()}');
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets(
    'many rows build lazily and the last supplied action is reachable',
    (tester) async {
      final invoked = <int>[];
      final state = ValueNotifier(
        _state([
          for (var i = 0; i < 30; i++)
            _entry(
              'row-$i',
              title: 'Retained conversation $i',
              actions: [
                DeletedDraftCleanupAction(
                  label: 'Check chat $i',
                  invoke: () => invoked.add(i),
                ),
              ],
            ),
        ]),
      );
      await _render(tester, state);
      await _open(tester);
      expect(find.text('Retained conversation 29'), findsNothing);
      await _reach(tester, _action('Check chat 29'), delta: 220);
      _minimumTarget(tester, _action('Check chat 29'));
      await tester.tap(_action('Check chat 29').hitTestable());
      expect(invoked, [29]);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'closing review during a held callback neither cancels nor repeats it',
    (tester) async {
      final completion = Completer<void>();
      late Future<void> delivery;
      var calls = 0;
      final state = ValueNotifier(
        const DeletedDraftCleanupPresentation.empty(),
      );
      void retry() {
        calls++;
        state.value = _state([
          _entry('held', detail: 'Cleaning retained local files.', busy: true),
        ]);
        delivery = completion.future.then((_) {
          state.value = const DeletedDraftCleanupPresentation.empty();
        });
        unawaited(delivery);
      }

      state.value = _state([
        _entry(
          'held',
          actions: [
            DeletedDraftCleanupAction(label: 'Retry cleanup', invoke: retry),
          ],
        ),
      ]);
      await _render(tester, state);
      addTearDown(() async {
        if (!completion.isCompleted) completion.complete();
        await tester.pump();
      });
      await _open(tester);
      await tester.tap(_action('Retry cleanup'));
      await tester.pump();
      expect(calls, 1);
      expect(_action('Retry cleanup'), findsNothing);
      await tester.pump();
      expect(find.byType(StudioLoading), findsOneWidget);
      await tester.tap(find.byTooltip('Close chat recovery'));
      await tester.pumpAndSettle();
      expect(find.byKey(_listKey), findsNothing);
      expect(find.byKey(_reviewKey), findsOneWidget);
      completion.complete();
      // Await the supplied callback's state publication before requesting its
      // render frame; completing its input alone does not settle its .then.
      await delivery;
      expect(state.value.entries, isEmpty);
      await tester.pump();
      expect(calls, 1);
      expect(find.byKey(_reviewKey), findsNothing);
      expect(find.text('Retained chat list'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
