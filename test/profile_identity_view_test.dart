import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/screens/administration/admin_identity_page.dart';
import 'package:wing/core/services/profile_identity_edit_session.dart';

import 'support/administration_fixture.dart';

void main() {
  testWidgets('identity keeps a same-field change made elsewhere', (
    tester,
  ) async {
    final fixture = AdministrationFixture();
    var description = 'Opening description';
    const soul = 'Opening SOUL.\n';
    fixture.override = (method, path, query, body) async {
      if (method == 'GET' && path == 'profiles') {
        return {
          'profiles': [
            {'name': 'work', 'path': '/fixture/work'},
          ],
        };
      }
      if (method == 'GET' && path == 'profiles/active') {
        return {'current': 'work', 'active': 'work'};
      }
      if (method == 'GET' && path == 'profiles/work/soul') {
        return {'content': soul, 'exists': true};
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
      if (method == 'PUT' && path == 'profiles/work/description') {
        description = body!['description'] as String;
        return {
          'ok': true,
          'description': description,
          'description_auto': false,
        };
      }
      throw StateError('Unexpected request');
    };
    await tester.pumpWidget(
      MaterialApp(
        home: AdminIdentityPage(
          createSession: () =>
              ProfileIdentityEditSession(fixture.server.profile('work')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final field = find.byKey(const ValueKey('profile-description-field'));
    await tester.enterText(field, 'My pending edit');
    await tester.pumpAndSettle();
    description = 'Changed elsewhere';
    await tester.ensureVisible(find.byTooltip('Save changes'));
    await tester.tap(find.byTooltip('Save changes'));
    await tester.pumpAndSettle();
    expect(description, 'Changed elsewhere');
    expect(fixture.requests.where((request) => request.$1 != 'GET'), isEmpty);
    expect(
      fixture.rpcRequests.where(
        (request) => request.$2 == 'profiles.configure',
      ),
      isEmpty,
    );
    expect(tester.widget<TextField>(field).controller!.text, 'My pending edit');
    expect(find.textContaining('changed elsewhere'), findsWidgets);
  });
}
