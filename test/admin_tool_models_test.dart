import 'dart:async';
import 'package:wing/core/models/model_choice.dart';
import 'package:wing/core/services/connection_manager.dart';
import 'package:wing/core/services/profile_tool_setup_session.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/screens/administration/admin_tool_setup_page.dart';
import 'package:wing/core/theme/wing_theme.dart';

import 'support/administration_fixture.dart';

void main() {
  testWidgets('tool model is staged and stays available after a failed save', (
    tester,
  ) async {
    final fixture = AdministrationFixture();
    var current = 'old-model';
    var failWrite = true;
    final write = Completer<void>();
    fixture.override = (method, path, query, body) async {
      if (path == 'profiles') {
        return {
          'profiles': [
            {'name': 'personal', 'is_default': false},
          ],
        };
      }
      if (path == 'profiles/active') {
        return {'current': 'personal', 'active': 'personal'};
      }
      if (path == 'tools/toolsets/image_gen/models') {
        return {
          'name': 'image_gen',
          'provider': 'example',
          'plugin': 'example-plugin',
          'has_models': true,
          'default': 'old-model',
          'current': current,
          'models': [
            {
              'id': 'old-model',
              'display': 'Old model',
              'strengths': '',
              'speed': '',
              'price': '',
            },
            {
              'id': 'new-model',
              'display': 'New model',
              'strengths': '',
              'speed': '',
              'price': '',
            },
          ],
        };
      }
      if (path == 'tools/toolsets/image_gen/model' && method == 'PUT') {
        if (failWrite) {
          await write.future;
          throw const DashboardHttpException(
            400,
            'tools/toolsets/image_gen/model',
          );
        }
        current = body!['model'] as String;
        return {
          'ok': true,
          'name': 'image_gen',
          'model': current,
          'plugin': 'example-plugin',
        };
      }
      throw StateError('Unexpected $method $path');
    };
    final session = ProfileToolSetupSession(
      fixture.server.profile('personal'),
      tool: 'image_gen',
    );
    addTearDown(session.dispose);
    final editor = session.openModelEditor('example');
    await tester.pumpWidget(
      MaterialApp(
        theme: wingTheme(Brightness.light),
        home: AdminToolModelsPage(session: session, editor: editor),
      ),
    );
    await tester.pumpAndSettle();

    final oldModel = find.byKey(const Key('tool-model-example-old-model'));
    final newModel = find.byKey(const Key('tool-model-example-new-model'));
    expect(
      tester.getTopLeft(oldModel).dy,
      lessThan(tester.getTopLeft(newModel).dy),
    );
    expect(
      find.descendant(of: oldModel, matching: find.text('Selected')),
      findsOneWidget,
    );

    await tester.tap(newModel);
    await tester.pumpAndSettle();
    expect(
      tester.getTopLeft(newModel).dy,
      lessThan(tester.getTopLeft(oldModel).dy),
    );
    expect(
      find.descendant(
        of: newModel,
        matching: find.text('Pending selection · Use model to apply'),
      ),
      findsOneWidget,
    );
    expect(fixture.requests.where((request) => request.$1 == 'PUT'), isEmpty);
    await tester.tap(find.byTooltip('Save tool model'));
    await tester.pump();
    await tester.pump();
    expect(find.text('Saving…'), findsNothing);
    expect(find.byTooltip('Save tool model'), findsOneWidget);
    expect(find.bySemanticsLabel('Saving tool model'), findsOneWidget);
    write.complete();
    await tester.pumpAndSettle();
    expect(find.textContaining('Your edits are kept'), findsOneWidget);
    expect(current, 'old-model');

    failWrite = false;
    await tester.tap(find.byTooltip('Save tool model'));
    await tester.pumpAndSettle();
    expect(current, 'new-model');
    expect(
      find.descendant(of: newModel, matching: find.text('Selected')),
      findsOneWidget,
    );
    expect(
      fixture.requests.where((request) => request.$1 == 'PUT'),
      hasLength(2),
    );
    expect(tester.takeException(), isNull);
  });

  test(
    'closing the model child revokes a held unsent save while its parent remains',
    () async {
      final fixture = AdministrationFixture();
      final session = ProfileToolSetupSession(
        fixture.server.profile('personal'),
        tool: 'image_gen',
      );
      addTearDown(session.dispose);
      final entered = Completer<void>(), release = Completer<void>();
      var dispatches = 0;
      fixture.override = (method, path, query, body) async {
        if (path == 'profiles') {
          return {
            'profiles': [
              {'name': 'personal'},
            ],
          };
        }
        if (path == 'profiles/active') {
          return {'current': 'personal', 'active': 'personal'};
        }
        if (path.endsWith('/models')) {
          return _catalog('old-model');
        }
        if (path.endsWith('/config')) {
          return {
            'name': 'image_gen',
            'has_category': true,
            'active_provider': null,
            'providers': [],
          };
        }
        throw StateError('Unexpected $method $path');
      };
      fixture.mutationOverride =
          (method, path, query, body, canDispatch, onDispatched) async {
            entered.complete();
            await release.future;
            if (!canDispatch()) {
              throw StateError('Editor retired before dispatch');
            }
            dispatches++;
            onDispatched();
            return fixture.send(method, path, query, body);
          };
      final editor = session.openModelEditor('example');
      await session.loadModels(editor);
      session.stageModel(
        editor,
        const ModelChoice(provider: 'example', model: 'new-model'),
      );
      final saving = session.saveModel(editor);
      await entered.future;
      session.releaseModelEditor(editor);
      release.complete();
      await saving;
      expect(dispatches, 0);
      expect(fixture.requests.where((request) => request.$1 == 'PUT'), isEmpty);
      expect(session.state.pendingModel, 'new-model');
      expect(session.state.acknowledgement, isNull);
      expect(session.state.reviewRequired, isFalse);
      await session.refresh();
      expect(session.state.readinessVerified, isTrue);
      expect(session.state.busy, isFalse);
    },
  );

  test(
    'a physically effected unconfirmed model save requires read-only review',
    () async {
      final fixture = AdministrationFixture();
      final session = ProfileToolSetupSession(
        fixture.server.profile('personal'),
        tool: 'image_gen',
      );
      addTearDown(session.dispose);
      var current = 'old-model';
      fixture.override = (method, path, query, body) async {
        if (path == 'profiles') {
          return {
            'profiles': [
              {'name': 'personal'},
            ],
          };
        }
        if (path == 'profiles/active') {
          return {'current': 'personal', 'active': 'personal'};
        }
        if (path.endsWith('/models')) {
          return _catalog(current);
        }
        if (method == 'PUT') {
          current = body!['model'] as String;
          throw StateError('Connection lost after commit');
        }
        throw StateError('Unexpected $method $path');
      };
      final editor = session.openModelEditor('example');
      await session.loadModels(editor);
      session.stageModel(
        editor,
        const ModelChoice(provider: 'example', model: 'new-model'),
      );
      await session.saveModel(editor);
      expect(current, 'new-model');
      expect(
        fixture.requests.where((request) => request.$1 == 'PUT'),
        hasLength(1),
      );
      expect(session.state.pendingModel, 'new-model');
      expect(session.state.acknowledgement, isNull);
      expect(session.state.reviewRequired, isTrue);
      await session.saveModel(editor);
      expect(
        fixture.requests.where((request) => request.$1 == 'PUT'),
        hasLength(1),
      );
      await session.loadModels(editor);
      expect(session.state.models!.current, 'new-model');
      expect(session.state.modelsVerified, isTrue);
      expect(session.state.canSaveModel, isFalse);
      expect(
        fixture.requests.where((request) => request.$1 == 'PUT'),
        hasLength(1),
      );
    },
  );
}

Map<String, dynamic> _catalog(String current) => {
  'name': 'image_gen',
  'provider': 'example',
  'plugin': 'example-plugin',
  'has_models': true,
  'default': 'old-model',
  'current': current,
  'models': [
    for (final id in ['old-model', 'new-model'])
      {'id': id, 'display': id, 'strengths': '', 'speed': '', 'price': ''},
  ],
};
