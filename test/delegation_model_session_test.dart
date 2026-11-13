import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/models/model_choice.dart';
import 'package:wing/core/models/settings_edit.dart';
import 'package:wing/core/services/delegation_model_session.dart';
import 'package:wing/core/services/settings_edit_session.dart';
import 'support/administration_fixture.dart';

void main() {
  late AdministrationFixture fixture;
  late DelegationModelSession session;
  setUp(() {
    fixture = AdministrationFixture();
    fixture.configs['personal']!['delegation'] = <String, dynamic>{
      'model': 'old',
      'provider': 'custom',
      'base_url': 'https://endpoint.invalid',
      'api_key': 'synthetic-key',
      'api_mode': 'chat_completions',
      'max_iterations': 17,
    };
    session = DelegationModelSession(fixture.server.profile('personal'));
  });
  tearDown(() {
    session.dispose();
  });
  const pick = ModelSelection.model(
    ModelChoice(provider: 'example', model: 'second'),
  );

  test(
    'one save switches provider/model and clears direct endpoint trio; unrelated settings remain',
    () async {
      await session.load();
      session.choose(pick);
      expect(fixture.settingsDispatches, 0);
      expect(await session.save(), SettingsSaveOutcome.confirmed);
      expect(fixture.settingsDispatches, 1);
      expect(fixture.configs['personal']!['delegation'], {
        'model': 'second',
        'provider': 'example',
        'base_url': '',
        'api_key': '',
        'api_mode': '',
        'max_iterations': 17,
      });
    },
  );
  test(
    'concurrent endpoint edit cannot silently attach to a chosen catalog route',
    () async {
      await session.load();
      session.choose(pick);
      (fixture.configs['personal']!['delegation'] as Map)['api_mode'] =
          'anthropic_messages';
      expect(await session.save(), SettingsSaveOutcome.failed);
      expect(fixture.settingsDispatches, 0);
      expect(session.edit.fields.any((field) => field.conflicted), isTrue);
      session.resolve(useServer: false);
      expect(await session.save(), SettingsSaveOutcome.confirmed);
      expect(setting(fixture.configs['personal']!, 'delegation.api_mode'), '');
    },
  );
  test(
    'inheritance is explicit and settings writes hold pending feedback through readback',
    () async {
      await session.load();
      session.choose(
        const ModelSelection.special(ModelSpecialChoice.automatic),
      );
      fixture.writeGate = Completer<void>();
      final save = session.save();
      await Future<void>.delayed(Duration.zero);
      expect(session.edit.saving, isTrue);
      fixture.writeGate!.complete();
      expect(await save, SettingsSaveOutcome.confirmed);
      expect(session.routeLabel, 'Inherit parent model');
    },
  );
}
