import 'package:flutter/foundation.dart';

import '../models/health_finding.dart';
import 'connection_manager.dart';
import 'health_snapshot.dart';
import 'profile_gateway.dart';
import 'workspace_connection_failure.dart';

/// One explicit credential check, retained for its profile across navigation.
class ProfileDiagnosticsController extends ChangeNotifier {
  ProfileDiagnosticsController({required ProfileGateway gateway})
    // ignore: prefer_initializing_formals
    : _gateway = gateway;

  ProfileGateway _gateway;
  bool _disposed = false;
  int _generation = 0;
  bool _checking = false;
  DateTime? _checkedAt;
  ProfileAccessResult _result = ProfileAccessResult.notChecked;

  (String?, String?) _selection = (null, null);

  Map<String, dynamic> snapshot() => {
    'model': _selection.$1,
    'provider': _selection.$2,
    'checkedAt': _checkedAt?.toUtc().toIso8601String(),
    'title': _result.title,
    'message': _result.message,
    'status': _result.status.name,
    'recovery': _result.recovery.name,
  };

  void restore(Map value) {
    _selection = (value['model'] as String?, value['provider'] as String?);
    _checkedAt = healthSnapshotTime(value['checkedAt']);
    _result = _checkedAt == null
        ? ProfileAccessResult.notChecked
        : ProfileAccessResult(
            value['title'] as String,
            value['message'] as String,
            AdministrationHealthStatus.values.byName(value['status'] as String),
            ProfileAccessRecovery.values.byName(value['recovery'] as String),
          );
  }

  /// Configuration changes invalidate both retained and in-flight checks.
  void updateModel(Map<String, dynamic>? data) {
    final selection = (
      data?['model'] is String ? data!['model'] as String : null,
      data?['provider'] is String ? data!['provider'] as String : null,
    );
    if (_disposed || selection == _selection) return;
    _selection = selection;
    invalidate();
  }

  void invalidate() {
    if (_disposed) return;
    _generation++;
    _checking = false;
    _checkedAt = null;
    _result = ProfileAccessResult.notChecked;
    notifyListeners();
  }

  ProfileAccessResult get result => _result;
  bool get checking => _checking;
  DateTime? get checkedAt => _checkedAt;

  AdministrationProfileHealthObservation get healthObservation =>
      AdministrationProfileHealthObservation(
        _gateway.scope,
        _result == ProfileAccessResult.notChecked && !_checking
            ? null
            : AdministrationHealthFinding(
                title: 'Provider credential check',
                detail: _checking ? 'Checking provider access…' : _result.title,
                status: _checking
                    ? AdministrationHealthStatus.unknown
                    : _result.status,
                checkedAt: _checking ? null : _checkedAt,
                destination: _result.recovery == ProfileAccessRecovery.provider
                    ? 'Access and connectors'
                    : null,
              ),
      );

  void updateGateway(ProfileGateway gateway) {
    if (_disposed || identical(_gateway, gateway)) return;
    _gateway = gateway;
    invalidate();
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    super.dispose();
  }

  ProfileAccessResult _resolvedResult(Map<String, dynamic> response) {
    final model = response['model'];
    final provider = response['provider'];
    if (model is! String ||
        model.isEmpty ||
        provider is! String ||
        provider.isEmpty) {
      return ProfileAccessResult.incomplete;
    }
    final (selectedModel, selectedProvider) = _selection;
    final differs =
        selectedModel != null &&
        selectedModel.isNotEmpty &&
        (model != selectedModel ||
            (selectedProvider != null &&
                selectedProvider.isNotEmpty &&
                selectedProvider != 'auto' &&
                provider != selectedProvider));
    return ProfileAccessResult(
      differs ? 'Selected model access unconfirmed' : 'Access is set up',
      differs
          ? 'Hermes resolved $model · $provider instead.'
          : _selection == (model, provider)
          ? ''
          : 'Checked $model · $provider.',
      differs
          ? AdministrationHealthStatus.warning
          : AdministrationHealthStatus.healthy,
      differs ? ProfileAccessRecovery.provider : ProfileAccessRecovery.none,
    );
  }

  Future<void> check() async {
    if (_disposed || _checking) return;
    final gateway = _gateway;
    final scope = _gateway.scope;
    final generation = ++_generation;
    _checking = true;
    notifyListeners();

    late final ProfileAccessResult result;
    try {
      // Stock Hermes 088f657ecf77674c7b8e2ededf4e3576d82e042c:
      // the native authority validates the request's profile before probing,
      // then returns readiness without echoing the profile in its result.
      // Resolves this profile's model and configured fallback chain.
      // It does not send a prompt or establish model availability / quota.
      final response = await retryTransientRead(
        () => gateway.call('setup.runtime_check'),
        isActive: () =>
            !_disposed &&
            generation == _generation &&
            identical(_gateway, gateway),
      );
      result =
          response.containsKey('profile') &&
              response['profile'] != scope.profileName
          ? ProfileAccessResult.incomplete
          : switch (response['ok']) {
              true => _resolvedResult(response),
              false => ProfileAccessResult.failure(response['error']),
              _ => ProfileAccessResult.incomplete,
            };
    } on DashboardHttpException catch (error) {
      result = {401, 403}.contains(error.statusCode)
          ? ProfileAccessResult.signIn
          : ProfileAccessResult.unavailable;
    } catch (_) {
      result = ProfileAccessResult.unavailable;
    }
    if (_disposed ||
        generation != _generation ||
        !identical(_gateway, gateway) ||
        _gateway.scope != scope) {
      return;
    }
    _result = result;
    _checkedAt = DateTime.now();
    _checking = false;
    notifyListeners();
  }
}

enum ProfileAccessRecovery { none, provider, connection }

class ProfileAccessResult {
  const ProfileAccessResult(
    this.title,
    this.message,
    this.status,
    this.recovery,
  );
  final String title;
  final String message;
  final AdministrationHealthStatus status;
  final ProfileAccessRecovery recovery;

  static const notChecked = ProfileAccessResult(
    'Credentials not checked',
    'Check whether Hermes has the provider credentials this profile needs.',
    AdministrationHealthStatus.unknown,
    ProfileAccessRecovery.none,
  );
  static const incomplete = ProfileAccessResult(
    'Check incomplete',
    'Hermes didn’t return a complete result for this profile.',
    AdministrationHealthStatus.unknown,
    ProfileAccessRecovery.none,
  );
  static const unavailable = ProfileAccessResult(
    'Check incomplete',
    'Couldn’t get a result from Hermes. Try again.',
    AdministrationHealthStatus.unknown,
    ProfileAccessRecovery.none,
  );
  static const signIn = ProfileAccessResult(
    'Server access denied',
    'Hermes rejected Wing’s access. Review the server address and sign-in details.',
    AdministrationHealthStatus.failure,
    ProfileAccessRecovery.connection,
  );

  static ProfileAccessResult failure(Object? error) {
    // Recognize stock messages without displaying arbitrary exception text,
    // which can contain keys, credential-file paths or authenticated URLs.
    if (error == 'No Hermes provider is configured.' ||
        error is String &&
            RegExp(
              r'^No usable credentials found for [a-zA-Z0-9_.-]+\.$',
            ).hasMatch(error)) {
      return const ProfileAccessResult(
        'Credentials missing',
        'Add an account or API key for this provider.',
        AdministrationHealthStatus.failure,
        ProfileAccessRecovery.provider,
      );
    }
    return const ProfileAccessResult(
      'Provider check failed',
      'Hermes couldn’t prepare this profile’s model.',
      AdministrationHealthStatus.failure,
      ProfileAccessRecovery.provider,
    );
  }
}
