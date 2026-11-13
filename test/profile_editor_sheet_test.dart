import 'dart:async';
import 'dart:convert';

import 'helpers/journey_controls.dart';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/services/profile_identity_edit_session.dart';
import 'package:wing/core/services/connection_manager.dart';
import 'support/administration_fixture.dart';
import 'package:wing/core/screens/administration/admin_identity_page.dart';

class _ProfileEditorFixture extends AdministrationFixture {
  _ProfileEditorFixture(super.id);
  String description = 'Work profile';
  String soul = 'Be precise.';
  bool failConfigure = false;
  bool partial = false;
  bool rejectDescriptionAndChangeSoul = false;
  Completer<void>? discoveryDelay;
  int discoveryCalls = 0;
  final calls = <(String, Map<String, dynamic>)>[];

  @override
  Future<Map<String, dynamic>> send(
    String method,
    String path,
    Map<String, String> query,
    Map<String, dynamic>? body,
  ) async {
    requests.add((method, path, {...query}, body == null ? null : {...body}));
    if (method == 'GET' && path == 'profiles') {
      discoveryCalls++;
      await discoveryDelay?.future;
      return {
        'profiles': [
          {'name': 'work', 'path': '/fixture/work'},
        ],
      };
    }
    if (method == 'GET' && path == 'profiles/active') {
      return {'current': 'work', 'active': 'work'};
    }
    if (method == 'GET' && path == 'files/read') {
      expect(query, {'path': '/fixture/work/profile.yaml'});
      final bytes = utf8.encode('description: ${jsonEncode(description)}\n');
      return {
        'name': 'profile.yaml',
        'path': '/fixture/work/profile.yaml',
        'size': bytes.length,
        'mime_type': 'application/octet-stream',
        'data_url':
            'data:application/octet-stream;base64,${base64Encode(bytes)}',
      };
    }
    if (method == 'GET' && path == 'profiles/work/soul') {
      return {'content': soul, 'exists': true};
    }
    if (method == 'PUT') {
      calls.add((path, {...body!}));
      if (failConfigure) throw StateError('private server failure');
      if (path == 'profiles/work/description') {
        if (rejectDescriptionAndChangeSoul) {
          soul = 'Central update';
          throw const DashboardHttpException(403, 'profiles/work/description');
        }
        description = body['description'] as String;
        return {
          'ok': true,
          'description': description,
          'description_auto': false,
        };
      }
      if (path == 'profiles/work/soul') {
        if (partial) {
          throw const DashboardHttpException(403, 'profiles/work/soul');
        }
        soul = body['content'] as String;
        return {'ok': true};
      }
    }
    throw StateError('Unexpected identity request');
  }
}

void main() {
  late _ProfileEditorFixture fixture;
  bool? result;

  setUp(() {
    fixture = _ProfileEditorFixture('Central server');
    result = null;
  });

  Future<void> openEditor(
    WidgetTester tester, {
    Size size = const Size(800, 900),
    double textScale = 1,
    double keyboard = 0,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    tester.view.viewInsets = FakeViewPadding(bottom: keyboard);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: Scaffold(
          body: Builder(
            builder: (context) => FilledButton(
              onPressed: () async {
                result = await showAdminIdentityEditor(
                  context,
                  createSession: () => ProfileIdentityEditSession(
                    fixture.server.profile('work'),
                  ),
                );
              },
              child: const Text('Edit'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Edit'));
    await tester.pumpAndSettle();
  }

  Finder field(String key) => find.byKey(ValueKey(key));

  Future<void> tapSave(WidgetTester tester, {bool settle = true}) async {
    await tester.ensureVisible(find.byTooltip('Save changes'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Save changes'));
    if (settle) {
      await tester.pumpAndSettle();
    } else {
      await tester.pump();
    }
  }

  testWidgets(
    'journey identity field is reachable with retained Android keyboard',
    (tester) async {
      await openEditor(tester, size: const Size(393, 698), keyboard: 320);
      final description = field('profile-description-field');
      expect(description, findsOneWidget);
      expect(tester.widget<TextField>(description).enabled, isTrue);
      expect(description.hitTestable(), findsNothing);
      await revealJourneyControl(tester, description);
      expect(description.hitTestable(), findsOneWidget);
      await tester.enterText(description, 'Recovered keyboard draft');
      await tapSave(tester);
      expect(fixture.description, 'Recovered keyboard draft');
    },
  );

  testWidgets('loads captured scope and writes only the dirty field', (
    tester,
  ) async {
    await openEditor(tester);
    expect(find.text('Central server / work'), findsOneWidget);
    expect(
      find.text('Stored for this profile on Central server.'),
      findsOneWidget,
    );
    expect(
      tester
          .widget<TextField>(field('profile-description-field'))
          .controller!
          .text,
      'Work profile',
    );

    await tester.enterText(
      field('profile-description-field'),
      '  Mobile work  ',
    );
    await tapSave(tester);

    final write = fixture.calls.singleWhere(
      (call) => call.$1.startsWith('profiles/work/'),
    );
    expect(write.$1, 'profiles/work/description');
    expect(write.$2, {'description': 'Mobile work'});
    expect(fixture.discoveryCalls, 2);
    expect(fixture.description, 'Mobile work');
    expect(result, isTrue);
  });

  testWidgets('reports partial ACK and preserves the unapplied SOUL edit', (
    tester,
  ) async {
    fixture.partial = true;
    await openEditor(tester);
    await tester.enterText(field('profile-description-field'), '  Updated  ');
    await tester.enterText(field('profile-soul-field'), 'Keep this exact.\n');
    await tapSave(tester);

    expect(find.text('Saved: description.'), findsOneWidget);
    expect(
      find.text('Some fields were not saved. Review them before trying again.'),
      findsOneWidget,
    );
    expect(
      tester
          .widget<TextField>(field('profile-description-field'))
          .controller!
          .text,
      'Updated',
    );
    expect(
      tester.widget<TextField>(field('profile-soul-field')).controller!.text,
      'Keep this exact.\n',
    );
    expect(
      fixture.calls.where((call) => call.$1.startsWith('profiles/work/')),
      hasLength(2),
    );
    await tester.tap(find.byTooltip('Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('Discard unsaved changes?'), findsOneWidget);
    await tester.tap(find.byTooltip('Discard edits'));
    await tester.pumpAndSettle();
    expect(result, isTrue);
  });

  testWidgets('keeps intentional empty edits after an uncertain save', (
    tester,
  ) async {
    fixture.failConfigure = true;
    await openEditor(tester);
    await tester.enterText(field('profile-description-field'), '');
    await tester.enterText(field('profile-soul-field'), '');
    await tapSave(tester);

    expect(
      find.text(
        'The save could not be confirmed. Your edits are still here; check the profile before saving again.',
      ),
      findsOneWidget,
    );
    for (final key in ['profile-description-field', 'profile-soul-field']) {
      expect(tester.widget<TextField>(field(key)).controller!.text, isEmpty);
    }
    expect(
      fixture.calls.where((call) => call.$1.startsWith('profiles/work/')),
      hasLength(2),
    );
    expect(result, isNull);
  });

  testWidgets('refreshes untouched fields without adding them to a retry', (
    tester,
  ) async {
    fixture.rejectDescriptionAndChangeSoul = true;
    await openEditor(tester);
    await tester.enterText(field('profile-description-field'), 'Keep pending');
    await tapSave(tester);

    expect(
      tester
          .widget<TextField>(field('profile-description-field'))
          .controller!
          .text,
      'Keep pending',
    );
    expect(
      tester.widget<TextField>(field('profile-soul-field')).controller!.text,
      'Central update',
    );
    await tapSave(tester);
    final writes = fixture.calls
        .where((call) => call.$1.startsWith('profiles/work/'))
        .toList();
    expect(writes, hasLength(2));
    expect(writes.last.$2.containsKey('soul'), isFalse);
  });

  testWidgets('keeps fields and Save reachable on a narrow keyboard layout', (
    tester,
  ) async {
    await openEditor(
      tester,
      size: const Size(320, 700),
      textScale: 1.6,
      keyboard: 260,
    );
    expect(tester.takeException(), isNull);
    await tester.enterText(field('profile-soul-field'), 'Phone edit');
    await tester.ensureVisible(find.byTooltip('Save changes'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Save changes').hitTestable(), findsOneWidget);
    await tester.tap(find.byTooltip('Save changes'));
    await tester.pumpAndSettle();
    expect(fixture.soul, 'Phone edit');
    expect(result, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('blocks route and barrier dismissal while saving', (
    tester,
  ) async {
    final pending = Completer<void>();
    await openEditor(tester);
    fixture.discoveryDelay = pending;
    await tester.enterText(field('profile-description-field'), 'Captured edit');
    await tapSave(tester, settle: false);

    await tester.tapAt(const Offset(4, 4));
    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(find.text('Identity'), findsOneWidget);
    final close = tester.widget<IconButton>(
      find.ancestor(
        of: find.byTooltip('Cancel'),
        matching: find.byType(IconButton),
      ),
    );
    expect(close.onPressed, isNull);

    pending.complete();
    await tester.pumpAndSettle();
    expect(
      fixture.calls.where((call) => call.$1.startsWith('profiles/work/')),
      hasLength(1),
    );
    expect(result, isTrue);
  });

  testWidgets('keeps the captured gateway when the parent owner changes', (
    tester,
  ) async {
    final pending = Completer<void>();
    final other = _ProfileEditorFixture('Other server');
    const editorKey = ValueKey('captured-profile-editor');

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AdminIdentityPage(
            key: editorKey,
            createSession: () =>
                ProfileIdentityEditSession(fixture.server.profile('work')),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    fixture.discoveryDelay = pending;
    await tester.enterText(field('profile-description-field'), 'First edit');
    await tapSave(tester, settle: false);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AdminIdentityPage(
            key: editorKey,
            createSession: () =>
                ProfileIdentityEditSession(other.server.profile('work')),
          ),
        ),
      ),
    );
    pending.complete();
    await tester.pumpAndSettle();

    expect(
      fixture.calls.where((call) => call.$1.startsWith('profiles/work/')),
      hasLength(1),
    );
    expect(
      other.calls.where((call) => call.$1.startsWith('profiles/work/')),
      isEmpty,
    );
  });
}
