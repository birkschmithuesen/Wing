import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/dashboard_oauth_grant.dart';

class CloudAccessException implements Exception {
  const CloudAccessException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// One instance-bound runtime owner shared by all clients for the connection.
class DashboardOAuthSession {
  DashboardOAuthSession(
    this._grant, {
    this.persist,
    http.Client Function()? createClient,
  }) : _createClient = createClient ?? http.Client.new;

  DashboardOAuthGrant _grant;
  DashboardOAuthGrant get currentGrant => _grant;

  DashboardOAuthGrant get activeGrant {
    _requireActive();
    return _grant;
  }

  Future<void> Function()? persist;
  final http.Client Function() _createClient;
  Future<void>? _refreshing;
  bool _needsSave = false;
  bool _retired = false;

  bool get isActive => !_retired;

  void retire() => _retired = true;

  void _requireActive() {
    if (_retired) throw StateError('This connection sign-in has been retired.');
  }

  void invalidateRejectedBearer(String? authorization) {
    if (authorization != 'Bearer ${_grant.accessToken}') return;
    _grant = DashboardOAuthGrant(
      id: _grant.id,
      baseUrl: _grant.baseUrl,
      accessToken: _grant.accessToken,
      refreshToken: _grant.refreshToken,
      expiresAt: DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
    );
  }

  Future<String> bearerFor(String destination) async {
    _requireActive();
    if (DashboardOAuthGrant.canonicalBase(destination) != _grant.baseUrl) {
      throw const CloudAccessException(
        'This sign-in belongs to a different Hermes instance.',
      );
    }
    if (_needsSave) {
      await persist?.call();
      _needsSave = false;
    }
    _requireActive();
    if (!_grant.expiresAt.isAfter(
      DateTime.now().add(const Duration(seconds: 30)),
    )) {
      final pending = _refreshing ??= _refresh();
      try {
        await pending;
      } finally {
        if (identical(_refreshing, pending)) _refreshing = null;
      }
    }
    _requireActive();
    return _grant.accessToken;
  }

  Future<void> _refresh() async {
    _requireActive();
    final client = _createClient();
    try {
      final request =
          http.Request(
              'POST',
              Uri.parse('${_grant.baseUrl}/auth/native/refresh'),
            )
            ..followRedirects = false
            ..headers['Content-Type'] = 'application/json'
            ..body = jsonEncode({
              'provider': 'nous',
              'refresh_token': _grant.refreshToken,
            });
      final response = await client
          .send(request)
          .then(http.Response.fromStream)
          .timeout(const Duration(seconds: 20));
      if (response.statusCode == 401 || response.statusCode == 403) {
        throw const CloudAccessException(
          'Sign in to Hermes Cloud again from this connection’s settings.',
        );
      }
      if (response.statusCode != 200) {
        throw const CloudAccessException(
          'Couldn’t renew this Hermes sign-in. Try again.',
        );
      }
      _requireActive();
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final access = data['access_token'] as String;
      final refresh = data['refresh_token'] as String;
      final expiry = DashboardOAuthGrant.tokenExpiry(data['expires_at']);
      if (data['provider'] != 'nous' || access.isEmpty || refresh.isEmpty) {
        throw const FormatException();
      }
      _grant = DashboardOAuthGrant(
        id: _grant.id,
        baseUrl: _grant.baseUrl,
        accessToken: access,
        refreshToken: refresh,
        expiresAt: expiry,
      );
      // Retain rotated tokens even if storage is temporarily unavailable. Never
      // replay the old refresh token; retry persisting before the next request.
      _needsSave = true;
      await persist?.call();
      _needsSave = false;
    } on CloudAccessException {
      rethrow;
    } catch (_) {
      throw const CloudAccessException(
        'Couldn’t renew or save this Hermes sign-in. Try again.',
      );
    } finally {
      client.close();
    }
  }
}
