import 'package:wing/core/services/dashboard_oauth_session.dart';
import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:wing/core/services/hermes_cloud.dart';

class _Browser implements CloudBrowser {
  final cookies = <String?>['portal-cookie'];
  final calls = <({bool signIn, bool switchAccount})>[];
  String Function(Uri url, String callback)? callback;
  Completer<String?>? pending;
  @override
  Future<String?> portalCookie({
    bool signIn = false,
    bool switchAccount = false,
  }) async {
    calls.add((signIn: signIn, switchAccount: switchAccount));
    return pending == null ? cookies.removeAt(0) : pending!.future;
  }

  @override
  Future<String?> authorize(String url, String redirect) async =>
      callback!(Uri.parse(url), redirect);
  @override
  Future<void> cancel() async {}
}

const _instance = CloudInstance(
  id: 'a',
  name: 'Research',
  state: 'running',
  dashboardUrl: 'https://agent.example/hermes',
);

void main() {
  test(
    'discovery sends Portal cookie only to Portal and handles organization selection',
    () async {
      final browser = _Browser()..cookies.add('portal-cookie');
      var requests = 0;
      final cloud = HermesCloud(
        browser: browser,
        client: MockClient((request) async {
          expect(request.url.origin, HermesCloud.portal);
          expect(request.followRedirects, false);
          expect(request.headers['Cookie'], 'portal-cookie');
          expect(request.headers, isNot(contains('Authorization')));
          if (++requests == 1) {
            return http.Response(
              jsonEncode({
                'error': 'org_selection_required',
                'orgs': [
                  {'id': 'team', 'name': 'Team'},
                ],
              }),
              409,
            );
          }
          expect(request.url.queryParameters, {'org': 'team'});
          return http.Response(
            jsonEncode({
              'org': {'id': 'team', 'name': 'Team'},
              'agents': [
                {
                  'id': 'a',
                  'name': 'Research',
                  'status': 'running',
                  'dashboardGatewayState': 'ready',
                  'dashboardUrl': 'https://agent.example/hermes/',
                },
                {
                  'id': 'b',
                  'name': 'Sleeping',
                  'status': 'stopped',
                  'dashboardGatewayState': 'ready',
                  'dashboardUrl': 'https://sleeping.example',
                },
              ],
            }),
            200,
          );
        }),
      );
      expect((await cloud.discover())!.organizations.single.id, 'team');
      final found = (await cloud.discover(organization: 'team'))!;
      expect(found.organization!.name, 'Team');
      expect(found.instances.first.canConnect, true);
      expect(
        found.instances.first.dashboardUrl,
        'https://agent.example/hermes',
      );
      expect(found.instances.last.canConnect, false);
      cloud.close();
    },
  );

  test('cancelled account switch does not open sign-in again', () async {
    final browser = _Browser()..cookies[0] = null;
    final cloud = HermesCloud(
      browser: browser,
      client: MockClient((_) async => throw StateError('No request expected')),
    );
    expect(await cloud.discover(switchAccount: true), isNull);
    expect(browser.calls, [(signIn: true, switchAccount: true)]);
    cloud.close();
  });

  test('cancelled discovery cannot reopen a late browser request', () async {
    final browser = _Browser()..pending = Completer<String?>();
    final cloud = HermesCloud(browser: browser);
    final pending = cloud.discover();
    await cloud.cancel();
    browser.pending!.complete(null);
    expect(await pending, isNull);
    expect(browser.calls, hasLength(1));
    cloud.close();
  });

  test(
    'instance auth binds state, loopback callback and S256 verifier',
    () async {
      late Uri authorize;
      final browser = _Browser()
        ..callback = (url, redirect) {
          authorize = url;
          return Uri.parse(redirect)
              .replace(
                queryParameters: {
                  'code': 'one-use',
                  'state': url.queryParameters['state']!,
                },
              )
              .toString();
        };
      final cloud = HermesCloud(
        browser: browser,
        client: MockClient((request) async {
          expect(
            request.url.toString(),
            'https://agent.example/hermes/auth/native/token',
          );
          expect(request.followRedirects, false);
          expect(request.headers, isNot(contains('Cookie')));
          final body = jsonDecode(request.body) as Map;
          expect(body['code'], 'one-use');
          expect(
            base64UrlEncode(
              sha256
                  .convert(utf8.encode(body['code_verifier'] as String))
                  .bytes,
            ).replaceAll('=', ''),
            authorize.queryParameters['code_challenge'],
          );
          expect(authorize.queryParameters['provider'], 'nous');
          expect(authorize.queryParameters['code_challenge_method'], 'S256');
          return http.Response(
            jsonEncode({
              'provider': 'nous',
              'access_token': 'access',
              'refresh_token': 'refresh',
              'expires_at':
                  DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600,
            }),
            200,
          );
        }),
      );
      final session = (await cloud.signIn(_instance))!;
      expect(session.currentGrant.baseUrl, _instance.dashboardUrl);
      expect(session.currentGrant.accessToken, 'access');
      cloud.close();
    },
  );

  for (final close in [false, true]) {
    test(
      'retired ${close ? 'closed' : 'cancelled'} token exchange returns no owner',
      () async {
        final browser = _Browser()
          ..callback = (url, redirect) => Uri.parse(redirect)
              .replace(
                queryParameters: {
                  'code': 'one-use',
                  'state': url.queryParameters['state']!,
                },
              )
              .toString();
        final started = Completer<void>();
        final release = Completer<void>();
        final cloud = HermesCloud(
          browser: browser,
          client: MockClient((_) async {
            started.complete();
            await release.future;
            return http.Response(
              jsonEncode({
                'provider': 'nous',
                'access_token': 'test-access',
                'refresh_token': 'test-refresh',
                'expires_at':
                    DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600,
              }),
              200,
            );
          }),
        );
        final pending = cloud.signIn(_instance);
        await started.future;
        if (close) {
          cloud.close();
        } else {
          await cloud.cancel();
        }
        release.complete();
        expect(await pending, isNull);
        if (!close) cloud.close();
      },
    );
  }

  for (final defect in ['state', 'host', 'fragment', 'duplicate']) {
    test('rejects $defect callback before exchanging any code', () async {
      final browser = _Browser()
        ..callback = (url, redirect) {
          var result = Uri.parse(redirect).replace(
            queryParameters: {
              'code': 'one-use',
              'state': url.queryParameters['state']!,
            },
          );
          if (defect == 'state') {
            result = result.replace(
              queryParameters: {'code': 'one-use', 'state': 'wrong'},
            );
          }
          if (defect == 'host') result = result.replace(host: 'other.example');
          if (defect == 'fragment') {
            result = result.replace(fragment: 'anything');
          }
          return '$result${defect == 'duplicate' ? '&code=another' : ''}';
        };
      final cloud = HermesCloud(
        browser: browser,
        client: MockClient(
          (_) async => throw StateError('No token exchange allowed'),
        ),
      );
      await expectLater(
        cloud.signIn(_instance),
        throwsA(isA<CloudAccessException>()),
      );
      cloud.close();
    });
  }
}
