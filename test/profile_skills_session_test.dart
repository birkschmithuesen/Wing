import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/services/profile_skills_session.dart';
import 'support/administration_fixture.dart';

void main() {
  test(
    'closing a borrowed skill editor revokes a held unsent save while the library remains',
    () async {
      final fixture = AdministrationFixture();
      final session = ProfileSkillsSession.library(
        fixture.server.profile('personal'),
      );
      addTearDown(session.dispose);
      final entered = Completer<void>(), release = Completer<void>();
      fixture.override = (_, path, _, _) async => switch (path) {
        'profiles' => {
          'profiles': [
            {'name': 'personal'},
          ],
        },
        'profiles/active' => {'current': 'personal', 'active': 'personal'},
        'skills' => _library,
        'skills/content' => {
          'name': 'research',
          'content': 'Opening instructions',
        },
        _ => throw StateError('Unexpected request $path'),
      };
      var dispatches = 0;
      fixture.mutationOverride =
          (method, path, query, body, canDispatch, onDispatched) async {
            entered.complete();
            await release.future;
            if (!canDispatch()) {
              throw StateError('Child retired before dispatch');
            }
            dispatches++;
            onDispatched();
            return fixture.send(method, path, query, body);
          };
      await session.refresh();
      final detail = session.openSkill(session.state.installed.single);
      await session.loadDetail(detail);
      final editor = session.openEditor(detail);
      session.edit(editor, 'My instructions');
      final saving = session.save(editor);
      await entered.future;
      session.releaseEditor(editor);
      release.complete();
      await saving;
      expect(dispatches, 0);
      expect(fixture.requests.where((r) => r.$1 == 'PUT'), isEmpty);
      expect(session.state.edit!.draft, 'My instructions');
      expect(session.state.edit!.saved, 'Opening instructions');
      expect(session.state.reviewRequired, isFalse);
      await session.loadDetail(detail);
      expect(session.state.verified, isTrue);
      expect(session.state.instructions!.content, 'Opening instructions');
    },
  );

  test(
    'an acknowledged instruction save survives failing readback without repeating the write',
    () async {
      final fixture = AdministrationFixture();
      final session = ProfileSkillsSession.library(
        fixture.server.profile('personal'),
      );
      addTearDown(session.dispose);
      var content = 'Opening instructions', unavailable = false;
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
        if (path == 'skills') return _library;
        if (method == 'PUT') {
          content = body!['content'] as String;
          unavailable = true;
          return {
            'success': true,
            'message': 'Skill updated',
            'path': '/profiles/personal/skills/research',
          };
        }
        if (path == 'skills/content') {
          if (unavailable) throw const FormatException('Malformed readback');
          return {'name': 'research', 'content': content};
        }
        throw StateError('Unexpected $method $path');
      };
      await session.refresh();
      final detail = session.openSkill(session.state.installed.single);
      await session.loadDetail(detail);
      final editor = session.openEditor(detail);
      session.edit(editor, 'Saved instructions');
      await session.save(editor);
      expect(content, 'Saved instructions');
      expect(fixture.requests.where((r) => r.$1 == 'PUT'), hasLength(1));
      expect(session.state.edit!.saved, 'Saved instructions');
      expect(session.state.edit!.draft, 'Saved instructions');
      expect(
        session.state.notice,
        'Instructions saved. Hermes can reload them in this chat.',
      );
      expect(session.state.verified, isFalse);
      expect(session.state.reviewRequired, isFalse);
      await session.save(editor);
      expect(fixture.requests.where((r) => r.$1 == 'PUT'), hasLength(1));
      unavailable = false;
      await session.loadDetail(detail);
      expect(session.state.instructions!.content, 'Saved instructions');
      expect(session.state.verified, isTrue);
      expect(fixture.requests.where((r) => r.$1 == 'PUT'), hasLength(1));
    },
  );
}

const _library = <String, dynamic>{
  'data': [
    {
      'name': 'research',
      'description': 'Research',
      'provenance': 'agent',
      'locked': false,
      'usage': 3,
      'enabled': true,
    },
  ],
};
