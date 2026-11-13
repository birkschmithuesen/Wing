import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/models/model_choice.dart';
import 'package:wing/core/models/settings_edit.dart';
import 'package:wing/core/services/settings_edit_session.dart';
import 'package:wing/core/services/connection_manager.dart';
import 'support/administration_fixture.dart';

class _SettingsFixture extends AdministrationFixture {
  final writeStarted = Completer<void>();
  Object? writeFailure;
  Object? readbackFailure;
  bool writeAcknowledged = false;

  @override
  Future<Map<String, dynamic>> send(
    String method,
    String path,
    Map<String, String> query,
    Map<String, dynamic>? body,
  ) async {
    if (method == 'PUT' && path == 'config' && !writeStarted.isCompleted) {
      writeStarted.complete();
    }
    if (method == 'PUT' && path == 'config' && writeFailure != null) {
      throw writeFailure!;
    }
    if (method == 'GET' &&
        path == 'config' &&
        writeAcknowledged &&
        readbackFailure != null) {
      throw readbackFailure!;
    }
    final result = await super.send(method, path, query, body);
    if (method == 'PUT' && path == 'config') writeAcknowledged = true;
    return result;
  }
}

void main() {
  _SettingsFixture stockFixture() {
    final fixture = _SettingsFixture();
    // Stock JSON objects accept null and heterogeneous values. Dart literals
    // otherwise infer narrow nested map types that cannot model those responses.
    for (final entry in fixture.configs.entries.toList()) {
      fixture.configs[entry.key] =
          jsonDecode(jsonEncode(entry.value)) as Map<String, dynamic>;
    }
    return fixture;
  }

  Future<SettingsEditSession> open(
    AdministrationFixture fixture, {
    List<AdminField>? fields,
    ConfiguredModel? expectedModel,
  }) async {
    final session = SettingsEditSession(
      fixture.server.profile('personal'),
      fields: fields ?? [memoryFields[2]],
      expectedModel: expectedModel,
    );
    await session.load();
    return session;
  }

  int writes(AdministrationFixture fixture) => fixture.settingsDispatches;
  for (final (status, detail) in [
    (403, 'memory.memory_char_limit is locked by organization policy'),
    (403, 'Cross-origin browser requests are not allowed'),
    (400, 'memory.memory_char_limit has an invalid value'),
    (409, 'Configuration changed elsewhere'),
    (413, 'The configuration is too large'),
  ]) {
    test(
      'definite config $status refusal retains explanation and editable draft: $detail',
      () async {
        final fixture = stockFixture()
          ..writeFailure = DashboardHttpException(
            status,
            'config?profile=personal',
            responseDetail: detail,
          );
        final session = await open(fixture);
        session.setText(memoryFields[2].key, '2500');
        expect(await session.save(), SettingsSaveOutcome.failed);
        expect(session.state.error, detail);
        expect(session.state.fields.single.text, '2500');
        expect(writes(fixture), 1);
        fixture.writeFailure = null;
        expect(await session.save(), SettingsSaveOutcome.confirmed);
        expect(writes(fixture), 2);
        session.dispose();
      },
    );
  }
  for (final failure in [
    TimeoutException('response lost'),
    const DashboardHttpException(
      500,
      'config',
      responseDetail: 'Internal server error',
    ),
    const DashboardHttpException(
      403,
      'auth/password-login',
      responseDetail: 'Access denied',
    ),
  ]) {
    test(
      'unconfirmed settings failure cannot become a managed refusal: $failure',
      () async {
        final fixture = stockFixture()..writeFailure = failure;
        final session = await open(fixture);
        session.setText(memoryFields[2].key, '2500');
        expect(await session.save(), SettingsSaveOutcome.uncertain);
        expect(await session.save(), SettingsSaveOutcome.blocked);
        expect(session.state.fields.single.text, '2500');
        expect(writes(fixture), 1);
        session.dispose();
      },
    );
  }
  test(
    'a config readback 403 does not turn an accepted write into a rejection',
    () async {
      final fixture = stockFixture()
        ..readbackFailure = const DashboardHttpException(
          403,
          'config',
          responseDetail: 'Access denied',
        );
      final session = await open(fixture);
      session.setText(memoryFields[2].key, '2500');
      expect(await session.save(), SettingsSaveOutcome.uncertain);
      expect(await session.save(), SettingsSaveOutcome.blocked);
      expect(setting(fixture.configs['personal']!, memoryFields[2].key), 2500);
      expect(writes(fixture), 1);
      session.dispose();
    },
  );
  for (final endpoint in ['config', 'profiles', 'model/info']) {
    test(
      'disposal during held $endpoint preflight sends no settings write',
      () async {
        final fixture = stockFixture();
        final session = await open(
          fixture,
          expectedModel: const ConfiguredModel(
            provider: 'Example provider',
            model: 'Research model',
          ),
        );
        session.setText(memoryFields[2].key, '2500');
        final held = Completer<Map<String, dynamic>>();
        final entered = Completer<void>();
        fixture.override = (method, path, query, body) async {
          if (path == endpoint) {
            entered.complete();
            return held.future;
          }
          final handler = fixture.override;
          fixture.override = null;
          try {
            return await fixture.send(method, path, query, body);
          } finally {
            fixture.override = handler;
          }
        };
        final result = session.save();
        await entered.future;
        session.dispose();
        held.complete(
          endpoint == 'config'
              ? {
                  'memory': {'memory_char_limit': 2000},
                }
              : endpoint == 'profiles'
              ? {
                  'profiles': [
                    {'name': 'personal'},
                  ],
                }
              : {'provider': 'Example provider', 'model': 'Research model'},
        );
        expect(await result, SettingsSaveOutcome.retired);
        expect(writes(fixture), 0);
      },
    );
  }
  test(
    'dispatched save completes after route disposal without publishing',
    () async {
      final fixture = stockFixture();
      final session = await open(fixture);
      session.setText(memoryFields[2].key, '2500');
      fixture.writeGate = Completer<void>();
      var notifications = 0;
      session.addListener(() => notifications++);
      final result = session.save();
      await fixture.writeStarted.future;
      session.dispose();
      final before = notifications;
      fixture.writeGate!.complete();
      expect(await result, SettingsSaveOutcome.retired);
      expect(setting(fixture.configs['personal']!, memoryFields[2].key), 2500);
      expect(notifications, before);
    },
  );
  test(
    'fresh conflict retains draft and rebases only the explicit field',
    () async {
      final fixture = stockFixture();
      final session = await open(
        fixture,
        fields: [memoryFields.first, memoryFields[2]],
      );
      session.setText(memoryFields[2].key, '2500');
      session.setValue(memoryFields.first.key, false);
      setSetting(fixture.configs['personal']!, memoryFields[2].key, 4000);
      expect(await session.save(), SettingsSaveOutcome.failed);
      expect(writes(fixture), 0);
      expect(session.state.fields.last.text, '2500');
      expect(session.state.fields.last.serverText, '4000');
      session.resolve(memoryFields[2].key, useServer: false);
      setSetting(fixture.configs['personal']!, memoryFields[2].key, 5000);
      expect(await session.save(), SettingsSaveOutcome.failed);
      expect(writes(fixture), 0);
      session.resolve(memoryFields[2].key, useServer: true);
      expect(session.state.fields.last.text, '5000');
      expect(await session.save(), SettingsSaveOutcome.confirmed);
      expect(
        setting(fixture.configs['personal']!, memoryFields.first.key),
        false,
      );
      expect(setting(fixture.configs['personal']!, memoryFields[2].key), 5000);
      session.dispose();
    },
  );
  test(
    'disjoint server edit survives and already-converged intent sends nothing',
    () async {
      final fixture = stockFixture();
      final session = await open(fixture);
      session.setText(memoryFields[2].key, '2500');
      setSetting(fixture.configs['personal']!, memoryFields.first.key, false);
      setSetting(fixture.configs['personal']!, memoryFields[2].key, 2500);
      expect(await session.save(), SettingsSaveOutcome.confirmed);
      expect(writes(fixture), 0);
      expect(
        setting(fixture.configs['personal']!, memoryFields.first.key),
        false,
      );
      expect(session.state.dirtyCount, 0);
      session.dispose();
    },
  );
  test(
    'unknown readback blocks replay until fresh explicit field review',
    () async {
      final fixture = stockFixture()..ignoreSave = true;
      final session = await open(fixture);
      session.setText(memoryFields[2].key, '2500');
      expect(await session.save(), SettingsSaveOutcome.uncertain);
      expect(await session.save(), SettingsSaveOutcome.blocked);
      expect(writes(fixture), 1);
      expect(session.state.fields.single.text, '2500');
      fixture.ignoreSave = false;
      await session.reviewUncertain();
      expect(session.state.fields.single.conflicted, true);
      expect(writes(fixture), 1);
      session.resolve(memoryFields[2].key, useServer: false);
      expect(await session.save(), SettingsSaveOutcome.confirmed);
      expect(writes(fixture), 2);
      session.dispose();
    },
  );
  test(
    'malformed late load retains opened draft and a newer response wins',
    () async {
      final fixture = stockFixture();
      final session = await open(fixture);
      session.setText(memoryFields[2].key, '2500');
      final held = Completer<Map<String, dynamic>>();
      var schemas = 0;
      fixture.override = (method, path, query, body) async {
        if (path == 'config/schema') {
          if (++schemas == 1) {
            return held.future;
          }
          return {'fields': 'malformed'};
        }
        return {
          'memory': {'memory_char_limit': 9000},
        };
      };
      final old = session.load();
      await session.load();
      held.complete({'fields': {}});
      await old;
      expect(session.state.hasObservation, true);
      expect(session.state.fields.single.text, '2500');
      expect(session.state.error, isNotNull);
      session.dispose();
    },
  );
  test(
    'unknown toggle never defaults to true and current catalogue choice stays visible',
    () async {
      final fixture = stockFixture();
      setSetting(fixture.configs['personal']!, 'memory.memory_enabled', null);
      setSetting(
        fixture.configs['personal']!,
        'approvals.mode',
        'current-stock-choice',
      );
      final session = await open(
        fixture,
        fields: [memoryFields.first, approvalFields.first],
      );
      expect(session.state.fields.first.value, null);
      expect(session.state.dirtyCount, 0);
      expect(
        session.state.fields.last.choices,
        contains('current-stock-choice'),
      );
      session.setValue('approvals.mode', 'invented');
      expect(session.state.dirtyCount, 0);
      session.setValue(memoryFields.first.key, false);
      expect(await session.save(), SettingsSaveOutcome.confirmed);
      expect(
        setting(fixture.configs['personal']!, 'memory.memory_enabled'),
        false,
      );
      session.dispose();
    },
  );
  test(
    'percentage parsing rejects nonfinite/range errors and sends canonical fraction',
    () async {
      final fixture = stockFixture();
      setSetting(fixture.configs['personal']!, 'compression.threshold', .29);
      final session = await open(fixture, fields: [compressionFields[1]]);
      expect(session.state.fields.single.text, '29');
      for (final text in ['NaN', 'Infinity', '101', '-1']) {
        session.setText('compression.threshold', text);
        expect(await session.save(), SettingsSaveOutcome.invalid);
        expect(writes(fixture), 0);
      }
      session.setText('compression.threshold', '8.123456789e1');
      expect(await session.save(), SettingsSaveOutcome.confirmed);
      expect(
        setting(fixture.configs['personal']!, 'compression.threshold'),
        .8123456789,
      );
      session.dispose();
    },
  );
  for (final changed in ['provider', 'model']) {
    test(
      'canonical automatic model $changed change prevents settings dispatch',
      () async {
        final fixture = stockFixture();
        final session = await open(
          fixture,
          expectedModel: const ConfiguredModel(
            provider: '',
            model: 'automatic-model',
          ),
        );
        session.setText(memoryFields[2].key, '2500');
        fixture.override = (method, path, query, body) async {
          if (path == 'model/info') {
            return {
              'provider': changed == 'provider' ? 'new-provider' : '',
              'model': changed == 'model' ? 'new-model' : 'automatic-model',
            };
          }
          final handler = fixture.override;
          fixture.override = null;
          try {
            return await fixture.send(method, path, query, body);
          } finally {
            fixture.override = handler;
          }
        };
        expect(await session.save(), SettingsSaveOutcome.failed);
        expect(writes(fixture), 0);
        expect(session.state.fields.single.text, '2500');
        session.dispose();
      },
    );
  }
  test(
    'same canonical automatic model permits metadata-owned optional settings',
    () async {
      final fixture = stockFixture();
      final field = AdminField(
        'agent.reasoning_effort',
        'Reasoning',
        AdminFieldKind.choice,
        choices: ['', 'low', 'high'],
        modelCapability: true,
      );
      fixture.override = (method, path, query, body) async {
        if (path == 'model/info') {
          return {'provider': '', 'model': 'automatic-model'};
        }
        final handler = fixture.override;
        fixture.override = null;
        try {
          return await fixture.send(method, path, query, body);
        } finally {
          fixture.override = handler;
        }
      };
      final session = await open(
        fixture,
        fields: [field],
        expectedModel: const ConfiguredModel(
          provider: '',
          model: 'automatic-model',
        ),
      );
      session.setValue(field.key, 'high');
      expect(await session.save(), SettingsSaveOutcome.confirmed);
      expect(writes(fixture), 1);
      session.dispose();
    },
  );
}
