import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';

import '../models/dashboard_oauth_grant.dart';
import 'dashboard_oauth_session.dart';

class CloudOrganization {
  const CloudOrganization(this.id, this.name);
  final String id, name;
}

class CloudInstance {
  const CloudInstance({
    required this.id,
    required this.name,
    required this.state,
    this.dashboardUrl,
  });
  final String id, name, state;
  final String? dashboardUrl;
  bool get canConnect =>
      dashboardUrl != null &&
      !{
        'stopped',
        'stopping',
        'deleted',
        'deleting',
        'provisioning',
        'creating',
        'failed',
        'error',
        'starting',
      }.contains(state);
  String get statusLabel => switch (state) {
    'running' || 'ready' || 'online' => 'Available to connect',
    'stopped' => 'Stopped',
    'provisioning' || 'creating' || 'starting' => 'Starting',
    'failed' || 'error' => 'Needs attention',
    _ => dashboardUrl == null ? 'Not available yet' : 'Check connection',
  };
}

class CloudDiscovery {
  const CloudDiscovery({
    this.instances = const [],
    this.organizations = const [],
    this.organization,
  });
  final List<CloudInstance> instances;
  final List<CloudOrganization> organizations;
  final CloudOrganization? organization;

  factory CloudDiscovery.parse(int status, Map<String, dynamic> data) {
    if (status == 409 && data['error'] == 'org_selection_required') {
      final orgs = (data['orgs'] as List).map((value) {
        final row = value as Map;
        return CloudOrganization(row['id'] as String, row['name'] as String);
      }).toList();
      if (orgs.isEmpty) throw const FormatException();
      return CloudDiscovery(organizations: orgs);
    }
    if (status != 200 || data['agents'] is! List) throw const FormatException();
    final org = data['org'];
    return CloudDiscovery(
      organization: org is Map && org['id'] is String
          ? CloudOrganization(
              org['id'] as String,
              org['name'] as String? ?? 'Personal',
            )
          : null,
      instances: (data['agents'] as List).map((value) {
        final row = value as Map;
        final rawUrl = row['dashboardUrl'];
        final url = rawUrl is String && rawUrl.isNotEmpty
            ? DashboardOAuthGrant.canonicalBase(rawUrl)
            : null;
        final status = row['status'] as String? ?? 'unknown';
        return CloudInstance(
          id: row['id'] as String,
          name: row['name'] as String? ?? row['id'] as String,
          state:
              {
                'stopped',
                'stopping',
                'deleted',
                'deleting',
                'provisioning',
                'creating',
                'failed',
                'error',
                'starting',
              }.contains(status)
              ? status
              : row['dashboardGatewayState'] as String? ?? status,
          dashboardUrl: url,
        );
      }).toList(),
    );
  }
}

abstract interface class CloudBrowser {
  Future<String?> portalCookie({
    bool signIn = false,
    bool switchAccount = false,
  });
  Future<String?> authorize(String url, String callback);
  Future<void> cancel();
}

class AndroidCloudBrowser implements CloudBrowser {
  static const _channel = MethodChannel('com.tarkilhk.wing/hermes_cloud');
  @override
  Future<String?> portalCookie({
    bool signIn = false,
    bool switchAccount = false,
  }) => _channel.invokeMethod<String>('portal', {
    'signIn': signIn,
    'switchAccount': switchAccount,
  });
  @override
  Future<String?> authorize(String url, String callback) => _channel
      .invokeMethod<String>('authorize', {'url': url, 'callback': callback});
  @override
  Future<void> cancel() => _channel.invokeMethod<void>('cancel');
}

/// Portal identity discovers instances; each instance gets its own PKCE grant.
class HermesCloud {
  HermesCloud({CloudBrowser? browser, http.Client? client})
    : _browser = browser ?? AndroidCloudBrowser(),
      _client = client ?? http.Client();
  static const portal = 'https://portal.nousresearch.com';
  final CloudBrowser _browser;
  final http.Client _client;
  int _generation = 0;

  Future<CloudDiscovery?> discover({
    String? organization,
    bool switchAccount = false,
  }) async {
    final generation = ++_generation;
    var cookie = await _browser.portalCookie(
      switchAccount: switchAccount,
      signIn: switchAccount,
    );
    if (generation != _generation) return null;
    if (switchAccount && cookie == null) return null;
    if (cookie == null || cookie.isEmpty) {
      cookie = await _browser.portalCookie(signIn: true);
    }
    if (cookie == null || generation != _generation) return null;
    for (var attempt = 0; ; attempt++) {
      final uri = Uri.parse('$portal/api/agents').replace(
        queryParameters: organization == null ? null : {'org': organization},
      );
      final request = http.Request('GET', uri)
        ..followRedirects = false
        ..headers.addAll({'Cookie': cookie!, 'Accept': 'application/json'});
      final response = await _client
          .send(request)
          .then(http.Response.fromStream)
          .timeout(const Duration(seconds: 20));
      if (generation != _generation) return null;
      if (response.statusCode == 401 && attempt == 0) {
        cookie = await _browser.portalCookie(signIn: true);
        if (cookie == null || generation != _generation) return null;
        continue;
      }
      if (response.statusCode == 401 || response.statusCode == 403) {
        throw const CloudAccessException(
          'Nous Portal couldn’t confirm your access. Sign in again.',
        );
      }
      try {
        return CloudDiscovery.parse(
          response.statusCode,
          jsonDecode(response.body) as Map<String, dynamic>,
        );
      } catch (_) {
        throw const CloudAccessException(
          'Couldn’t load your Cloud instances. Try again.',
        );
      }
    }
  }

  String _nonce() => base64UrlEncode(
    List.generate(32, (_) => Random.secure().nextInt(256)),
  ).replaceAll('=', '');

  Future<DashboardOAuthSession?> signIn(CloudInstance instance) async {
    final generation = ++_generation;
    final base = DashboardOAuthGrant.canonicalBase(instance.dashboardUrl!);
    final verifier = _nonce(), state = _nonce();
    final callback = 'http://127.0.0.1:49152/wing/${_nonce()}';
    final authorize = Uri.parse('$base/auth/native/authorize').replace(
      queryParameters: {
        'provider': 'nous',
        'code_challenge_method': 'S256',
        'code_challenge': base64UrlEncode(
          sha256.convert(utf8.encode(verifier)).bytes,
        ).replaceAll('=', ''),
        'redirect_uri': callback,
        'state': state,
      },
    );
    final result = await _browser.authorize(authorize.toString(), callback);
    if (result == null || generation != _generation) return null;
    final returned = Uri.parse(result);
    if (returned.hasFragment ||
        Uri(
              scheme: returned.scheme,
              userInfo: returned.userInfo,
              host: returned.host,
              port: returned.port,
              path: returned.path,
            ).toString() !=
            callback ||
        returned.queryParametersAll['state']?.length != 1 ||
        returned.queryParameters['state'] != state ||
        returned.queryParametersAll['code']?.length != 1 ||
        (returned.queryParameters['code']?.isEmpty ?? true)) {
      throw const CloudAccessException(
        'The sign-in response couldn’t be verified. Try again.',
      );
    }
    final request = http.Request('POST', Uri.parse('$base/auth/native/token'))
      ..followRedirects = false
      ..headers['Content-Type'] = 'application/json'
      ..body = jsonEncode({
        'code': returned.queryParameters['code'],
        'code_verifier': verifier,
      });
    final response = await _client
        .send(request)
        .then(http.Response.fromStream)
        .timeout(const Duration(seconds: 20));
    if (generation != _generation) return null;
    if (response.statusCode != 200) {
      throw const CloudAccessException(
        'This Hermes instance couldn’t complete sign-in. Try again.',
      );
    }
    try {
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      if (data['provider'] != 'nous') throw const FormatException();
      return DashboardOAuthSession(
        DashboardOAuthGrant.fromMap({
          ...data,
          'id': const Uuid().v4(),
          'base_url': base,
          'expires_at': DashboardOAuthGrant.tokenExpiry(
            data['expires_at'],
          ).toIso8601String(),
        }),
      );
    } catch (_) {
      throw const CloudAccessException(
        'The instance returned an incomplete sign-in. Try again.',
      );
    }
  }

  Future<void> cancel() {
    _generation++;
    return _browser.cancel();
  }

  void close() {
    _generation++;
    _client.close();
    _browser.cancel().catchError((_) {});
  }
}
