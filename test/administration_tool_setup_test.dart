import 'package:wing/core/services/profile_tool_setup_session.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/screens/administration/admin_tool_setup_page.dart';
import 'package:wing/core/theme/wing_theme.dart';
import 'support/administration_fixture.dart';

void main() {
  testWidgets(
    'choosing a tool provider updates the selected row and moves it first',
    (tester) async {
      final fixture = AdministrationFixture();
      var active = 'Second';
      fixture.override = (method, path, query, body) async {
        if (path == 'profiles') {
          return {
            'profiles': [
              {'name': 'personal'},
            ],
          };
        }
        if (method == 'PUT') {
          active = body!['provider'] as String;
          return {'ok': true, 'name': 'image_gen', 'provider': active};
        }
        return {
          'name': 'image_gen',
          'has_category': true,
          'active_provider': active,
          'providers': [
            for (final name in ['First', 'Second', 'Third'])
              {
                'name': name,
                'badge': '',
                'tag': '',
                'env_vars': [],
                'requires_nous_auth': false,
                'status': 'ready',
                'is_active': name == active,
              },
          ],
        };
      };
      await tester.pumpWidget(
        MaterialApp(
          theme: wingTheme(Brightness.light),
          home: AdminToolSetupPage(
            createSession: () => ProfileToolSetupSession(
              fixture.server.profile('personal'),
              tool: 'image_gen',
            ),
            onCredential: (_, _) async {},
          ),
        ),
      );
      await tester.pumpAndSettle();

      final selected = find.byKey(const Key('tool-provider-Second'));
      expect(
        tester.getTopLeft(selected).dy,
        lessThan(
          tester.getTopLeft(find.byKey(const Key('tool-provider-First'))).dy,
        ),
      );
      expect(
        find.descendant(of: selected, matching: find.text('Selected')),
        findsOneWidget,
      );

      await tester.tap(
        find.descendant(
          of: find.byKey(const Key('tool-provider-Third')),
          matching: find.text('Use provider'),
        ),
      );
      await tester.pumpAndSettle();
      final updated = find.byKey(const Key('tool-provider-Third'));
      expect(
        tester.getTopLeft(updated).dy,
        lessThan(tester.getTopLeft(selected).dy),
      );
      expect(
        find.descendant(of: updated, matching: find.text('Selected')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: selected, matching: find.text('Selected')),
        findsNothing,
      );
      expect(active, 'Third');
      expect(
        fixture.requests.where((request) => request.$1 == 'PUT'),
        hasLength(1),
      );
    },
  );

  testWidgets('web highlights search and extraction selections separately', (
    tester,
  ) async {
    final fixture = AdministrationFixture();
    fixture.override = (_, path, _, _) async {
      if (path == 'profiles') {
        return {
          'profiles': [
            {'name': 'personal'},
          ],
        };
      }
      return {
        'name': 'web',
        'has_category': true,
        'active_provider': null,
        'active_search_backend': 'brave',
        'active_extract_backend': 'tavily',
        'providers': [
          {
            'name': 'Other',
            'web_backend': 'other',
            'badge': '',
            'tag': '',
            'env_vars': [],
            'requires_nous_auth': false,
            'is_active': false,
            'status': 'ready',
            'capabilities': ['search', 'extract'],
          },
          {
            'name': 'Tavily',
            'web_backend': 'tavily',
            'badge': '',
            'tag': '',
            'env_vars': [],
            'requires_nous_auth': false,
            'is_active': false,
            'status': 'ready',
            'capabilities': ['search', 'extract'],
          },
          {
            'name': 'Brave',
            'web_backend': 'brave',
            'badge': '',
            'tag': '',
            'env_vars': [],
            'requires_nous_auth': false,
            'is_active': false,
            'status': 'ready',
            'capabilities': ['search', 'extract'],
          },
        ],
      };
    };
    await tester.pumpWidget(
      MaterialApp(
        theme: wingTheme(Brightness.dark),
        home: AdminToolSetupPage(
          createSession: () => ProfileToolSetupSession(
            fixture.server.profile('personal'),
            tool: 'web',
          ),
          onCredential: (_, _) async {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    final tavily = find.byKey(const Key('tool-provider-Tavily'));
    final brave = find.byKey(const Key('tool-provider-Brave'));
    final other = find.byKey(const Key('tool-provider-Other'));
    expect(tester.getTopLeft(tavily).dy, lessThan(tester.getTopLeft(other).dy));
    expect(tester.getTopLeft(brave).dy, lessThan(tester.getTopLeft(other).dy));
    expect(
      find.descendant(of: tavily, matching: find.text('Selected for extract')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: brave, matching: find.text('Selected for search')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: other, matching: find.textContaining('Selected')),
      findsNothing,
    );
  });

  testWidgets(
    'browser selection accepts its active row alongside the cloud provider',
    (tester) async {
      final fixture = AdministrationFixture();
      var selected = false;
      fixture.override = (method, path, query, body) async {
        if (path == 'profiles') {
          return {
            'profiles': [
              {'name': 'personal'},
            ],
          };
        }
        if (method == 'PUT') {
          selected = true;
          return {'ok': true, 'name': 'browser', 'provider': 'Browser Use'};
        }
        return {
          'name': 'browser',
          'has_category': true,
          'active_provider': 'Local Browser',
          'providers': [
            {
              'name': 'Local Browser',
              'is_active': true,
              'badge': '',
              'tag': '',
              'env_vars': [],
              'requires_nous_auth': false,
              'status': 'ready',
            },
            {
              'name': 'Browser Use',
              'is_active': selected,
              'badge': '',
              'tag': '',
              'env_vars': [],
              'requires_nous_auth': false,
              'status': 'ready',
            },
          ],
        };
      };
      await tester.pumpWidget(
        MaterialApp(
          home: AdminToolSetupPage(
            createSession: () => ProfileToolSetupSession(
              fixture.server.profile('personal'),
              tool: 'browser',
            ),
            onCredential: (_, _) async {},
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Use provider').last);
      await tester.pumpAndSettle();
      expect(selected, isTrue);
      expect(find.text('Provider selection saved.'), findsOneWidget);
    },
  );

  for (final tool in ['x_search', 'homeassistant', 'spotify', 'langfuse']) {
    testWidgets('$tool exposes setup without a no-op provider switch', (
      tester,
    ) async {
      final fixture = AdministrationFixture();
      fixture.override = (_, _, _, _) async => {
        'name': tool,
        'has_category': true,
        'active_provider': null,
        'providers': [
          {
            'name': 'Integration',
            'post_setup': 'setup',
            'badge': '',
            'tag': '',
            'env_vars': [],
            'requires_nous_auth': false,
            'is_active': false,
            'status': 'needs_setup',
          },
        ],
      };
      await tester.pumpWidget(
        MaterialApp(
          home: AdminToolSetupPage(
            createSession: () => ProfileToolSetupSession(
              fixture.server.profile('personal'),
              tool: tool,
            ),
            onCredential: (_, _) async {},
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Use provider'), findsNothing);
      expect(find.text('Setup requirements'), findsOneWidget);
      expect(fixture.requests.where((r) => r.$1 == 'PUT'), isEmpty);
    });
  }
}
