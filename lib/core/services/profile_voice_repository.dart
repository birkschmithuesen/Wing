import '../models/profile_voice.dart';
import '../models/profile_tool_setup.dart';
import '../models/settings_edit.dart';
import 'administration_repository.dart';
import 'administration_operation_session.dart';
import 'hermes_voice.dart';

/// An exact admitted autosave target. Superseded or settled targets release
/// their lease; route retirement cannot invent a new target.
final class ProfileVoiceSaveTarget {
  ProfileVoiceSaveTarget._(this.voice, this._release);
  final String voice;
  final void Function() _release;
  bool _closed = false;
  void close() {
    if (_closed) return;
    _closed = true;
    _release();
  }
}

/// Stock profile configuration, provider readiness and speech adapter.
/// No catalog cache or pending draft is retained here.
class ProfileVoiceRepository {
  ProfileVoiceRepository(this._profile) {
    _profile.server.retain();
  }
  final ProfileAdministration _profile;
  bool _disposed = false;
  final _targets = <ProfileVoiceSaveTarget>{};
  String get profileName => _profile.name;
  String get scopeLabel => _profile.label;
  static const _base = 'tools/toolsets/tts';

  Future<ProfileVoiceConfiguration> load() async {
    if (_disposed) throw StateError('Voice route closed.');
    _profile.server.retain();
    try {
      final config = await _profile.config();
      final schema = await _profile.read('config/schema');
      return ProfileVoiceConfiguration.decode(config, schema);
    } finally {
      _profile.server.release();
    }
  }

  Future<ToolSetupReadiness> readiness() async {
    if (_disposed) throw StateError('Voice route closed.');
    _profile.server.retain();
    try {
      return ToolSetupReadiness.decode(
        await _profile.read('$_base/config'),
        'tts',
      );
    } finally {
      _profile.server.release();
    }
  }

  Future<List<ProfileVoiceChoice>> choices(String provider) async {
    if (_disposed) throw StateError('Voice route closed.');
    if (provider == 'edge') return edgeVoiceSuggestions;
    if (provider != 'elevenlabs') return const [];
    _profile.server.retain();
    try {
      final data = await _profile.read('audio/elevenlabs/voices');
      if (data['available'] != true) {
        throw const AdministrationFailure(
          'ElevenLabs voices are unavailable. Check the provider settings.',
        );
      }
      final seen = <String>{};
      return List.unmodifiable(
        administrationRows(data['voices']).map((row) {
          final id = row['voice_id'], name = row['name'], label = row['label'];
          if (id is! String ||
              id.isEmpty ||
              name is! String ||
              label is! String ||
              !seen.add(id)) {
            throw const FormatException('Invalid voice list');
          }
          return ProfileVoiceChoice(id, name, label == name ? '' : label);
        }),
      );
    } finally {
      _profile.server.release();
    }
  }

  Future<void> verify(ProfileVoiceSettings expected) async {
    final config = await _profile.config();
    if (setting(config, 'tts.provider') != expected.provider ||
        expected.key != null &&
            setting(config, expected.key!) != expected.voice) {
      throw const AdministrationFailure(
        'Voice settings changed elsewhere. Refresh to continue.',
      );
    }
  }

  ProfileVoiceSaveTarget admitVoice(String voice) {
    if (_disposed || voice.isEmpty || voice.length > 256) {
      throw const AdministrationFailure('Enter a valid voice ID.');
    }
    _profile.server.retain();
    late final ProfileVoiceSaveTarget target;
    target = ProfileVoiceSaveTarget._(voice, () {
      _targets.remove(target);
      _profile.server.release();
    });
    _targets.add(target);
    return target;
  }

  Future<ProfileVoiceSettings> save(
    ProfileVoiceSettings expected,
    ProfileVoiceSaveTarget target, {
    required void Function(String voice) onAcknowledged,
  }) async {
    bool active() => _targets.contains(target) && !target._closed;
    void check() {
      if (!active()) throw const SettingsEditRetired();
    }

    final key = expected.key;
    if (key == null) {
      throw const AdministrationFailure('Enter a valid voice ID.');
    }
    check();
    final latest = await _profile.config();
    check();
    final intent = SettingsEditIntent(
      baseline: {key: expected.voice, 'tts.provider': expected.provider},
      desired: {key: target.voice},
      invariants: {'tts.provider'},
    );
    final resolution = intent.resolve(latest);
    if (resolution.conflicts.isNotEmpty) {
      throw const AdministrationFailure(
        'Voice settings changed elsewhere. Refresh to continue.',
      );
    }
    final saved = ProfileVoiceSettings(expected.provider, key, target.voice);
    if (resolution.updates.isEmpty) return saved;
    await _profile.requireProfile();
    check();
    final patch = <String, dynamic>{};
    for (final entry in resolution.updates.entries) {
      setSetting(patch, entry.key, entry.value);
    }
    final result = await _profile.server.settingsWrite(
      _profile.name,
      patch,
      active,
      () {},
    );
    if (result['ok'] == false) {
      throw const SettingsWriteRejected('The server rejected this change.');
    }
    if (result['ok'] != true) throw const SettingsSaveUnconfirmed();
    onAcknowledged(target.voice);
    await verify(saved);
    return saved;
  }

  Future<ToolSetupAcknowledgement> selectProvider(
    ToolSetupProvider opening, {
    required bool Function() canDispatch,
    required void Function() onDispatched,
  }) async {
    _profile.server.retain();
    bool active() => !_disposed && canDispatch();
    try {
      if (!active()) throw const SettingsEditRetired();
      final latest = await readiness();
      if (!active()) throw const SettingsEditRetired();
      final row = latest.provider(opening.name);
      if (row == null ||
          row.speechProvider != opening.speechProvider ||
          row.requiresAccount != opening.requiresAccount) {
        throw const AdministrationFailure(
          'Provider setup changed. Refresh to continue.',
        );
      }
      await _profile.requireProfile();
      if (!active()) throw const SettingsEditRetired();
      final result = await _profile.server.ownedMutation(
        'PUT',
        '$_base/provider',
        {'profile': profileName},
        {'profile': profileName, 'provider': row.name},
        active,
        onDispatched,
      );
      if (result['ok'] != true ||
          result['name'] != 'tts' ||
          result['provider'] != row.name ||
          result['needs_nous_auth'] != null &&
              result['needs_nous_auth'] is! bool) {
        throw const FormatException('Provider selection was not acknowledged');
      }
      return ToolSetupAcknowledgement.provider(
        needsAccount: result['needs_nous_auth'] == true,
      );
    } finally {
      _profile.server.release();
    }
  }

  Future<AdministrationOperationSession> setup(
    String key, {
    required bool Function() canDispatch,
    required void Function() onDispatched,
  }) async {
    _profile.server.retain();
    bool active() => !_disposed && canDispatch();
    try {
      if (!active()) throw const SettingsEditRetired();
      final latest = await readiness();
      if (!active()) throw const SettingsEditRetired();
      if (!latest.providers.any((row) => row.setupKey == key)) {
        throw const AdministrationFailure(
          'Setup requirements changed. Refresh to continue.',
        );
      }
      await _profile.requireProfile();
      if (!active()) throw const SettingsEditRetired();
      final receipt = await _profile.server.ownedMutation(
        'POST',
        '$_base/post-setup',
        {'profile': profileName},
        {'profile': profileName, 'key': key},
        active,
        onDispatched,
      );
      if (receipt['key'] != key) {
        throw const FormatException('Unexpected setup receipt');
      }
      return AdministrationOperationSession.fromReceipt(
        _profile.server,
        receipt,
      );
    } finally {
      _profile.server.release();
    }
  }

  HermesVoice speech(
    ProfileVoiceSettings expected, {
    required bool Function() canDispatch,
  }) {
    var closed = false;
    bool active() => !closed && !_disposed && canDispatch();
    return HermesVoice(
      profile: profileName,
      closeClient: () => closed = true,
      request: (endpoint, body) async {
        _profile.server.retain();
        try {
          if (!active()) throw StateError('Playback stopped.');
          await verify(expected);
          if (!active()) throw StateError('Playback stopped.');
          final result = await _profile.server.ownedMutation(
            'POST',
            Uri.parse(endpoint).path,
            {'profile': profileName},
            body,
            active,
            () {},
          );
          if (!active()) throw StateError('Playback stopped.');
          await verify(expected);
          if (!active()) throw StateError('Playback stopped.');
          return result;
        } on AdministrationFailure catch (failure) {
          throw StateError(failure.message);
        } finally {
          _profile.server.release();
        }
      },
    );
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _profile.server.release();
  }
}
