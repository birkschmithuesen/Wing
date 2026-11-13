import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/models/model_choice.dart';
import 'package:wing/core/models/profile_model_defaults.dart';
import 'package:wing/core/services/profile_model_defaults_session.dart';

import 'support/model_defaults_fixture.dart';

void main() {
  late ModelDefaultsFixture fixture;
  late ProfileModelDefaultsSession edit;
  const after = ModelSelection.model(
    ModelChoice(provider: 'p', model: 'after'),
  );
  Future<bool> accept(HelperChangeConfirmation _) async => true;
  Future<HelperEditDraft> open() async {
    await edit.load();
    return (await edit.prepareHelper('vision'))!;
  }

  setUp(() {
    fixture = ModelDefaultsFixture();
    edit = ProfileModelDefaultsSession(fixture.server.profile('personal'));
    addTearDown(() => edit.dispose());
  });

  test(
    'typed observations preserve canonical automatic model and capabilities',
    () async {
      await edit.load();
      expect(edit.observation!.helpers, hasLength(11));
      expect(edit.observation!.settings.map((row) => row.kind), [
        ModelDefaultSettingKind.reasoning,
        ModelDefaultSettingKind.serviceTier,
      ]);
      fixture.provider = '';
      fixture.model = 'automatic-model';
      await edit.load();
      expect(edit.observation!.model.model, 'automatic-model');
      expect(edit.observation!.model.hasModel, isTrue);
      expect(edit.observation!.settings, isEmpty);
      expect(edit.access!.providerId, isNull);
    },
  );

  test('canonical helper parser accepts complete assignments', () {
    expect(
      HelperModelAssignment.fromResponse(
        fixture.copy({'tasks': fixture.helpers}),
      ),
      hasLength(fixture.helpers.length),
    );
  });

  for (final key in ['provider', 'model', 'base_url', 'reasoning_effort']) {
    test('canonical helper parser rejects missing $key', () {
      final missing = fixture.copy({'tasks': fixture.helpers});
      (missing['tasks'] as List).first.remove(key);
      expect(
        () => HelperModelAssignment.fromResponse(missing),
        throwsFormatException,
      );
    });
  }

  test('canonical helper parser refuses a non-string model', () {
    final malformed = fixture.copy({'tasks': fixture.helpers});
    (malformed['tasks'] as List).first['model'] = 9;
    expect(
      () => HelperModelAssignment.fromResponse(malformed),
      throwsFormatException,
    );
  });

  test('canonical helper parser rejects duplicate task identities', () {
    final duplicate = fixture.copy({'tasks': fixture.helpers});
    (duplicate['tasks'] as List).add((duplicate['tasks'] as List).first);
    expect(
      () => HelperModelAssignment.fromResponse(duplicate),
      throwsFormatException,
    );
  });

  for (final change in <String, Object?>{
    'provider': 'external',
    'model': 'external',
    'base_url': 'https://different.invalid',
    'reasoning_effort': 'high',
  }.entries) {
    test('picker opening ${change.key} remains a conflict baseline', () async {
      final draft = await open();
      fixture.vision[change.key] = change.value;
      expect(
        await edit.selectHelper(draft, after, confirm: accept),
        HelperSaveOutcome.failed,
      );
      expect(fixture.posts, isEmpty);
      expect(edit.pendingFor('vision')!.state, HelperChangeState.conflict);
      expect(edit.error, contains('changed elsewhere'));
    });
  }

  test(
    'successful readback preserves endpoint and reasoning for same provider',
    () async {
      fixture.vision.addAll({
        'base_url': 'https://synthetic.invalid',
        'reasoning_effort': 'high',
      });
      final draft = await open();
      expect(
        await edit.selectHelper(draft, after, confirm: accept),
        HelperSaveOutcome.saved,
      );
      expect(fixture.posts.single['profile'], 'personal');
      expect(fixture.posts.single['scope'], 'auxiliary');
      expect(fixture.posts.single.containsKey('reasoning_effort'), isFalse);
      expect(edit.pendingFor('vision'), isNull);
      expect(
        edit.observation!.helpers.first.baseUrl,
        'https://synthetic.invalid',
      );
      expect(edit.observation!.helpers.first.reasoningEffort, 'high');
    },
  );

  test('provider change follows stock endpoint clearing', () async {
    fixture.vision['base_url'] = 'https://synthetic.invalid';
    final draft = await open();
    const next = ModelSelection.model(
      ModelChoice(provider: 'other', model: 'other-model'),
    );
    expect(
      await edit.selectHelper(draft, next, confirm: accept),
      HelperSaveOutcome.saved,
    );
    expect(edit.observation!.helpers.first.baseUrl, '');
  });

  test(
    'lost acknowledgement is reconciled without resending a committed mutation',
    () async {
      final draft = await open();
      fixture.failAfterWrite = true;
      expect(
        await edit.selectHelper(draft, after, confirm: accept),
        HelperSaveOutcome.failed,
      );
      expect(edit.pendingFor('vision')!.state, HelperChangeState.uncertain);
      await edit.load();
      expect(
        await edit.retryHelper(
          'vision',
          confirm: (_) async => fail('No resend consent needed'),
        ),
        HelperSaveOutcome.saved,
      );
      expect(fixture.posts, hasLength(1));
      expect(edit.pendingFor('vision'), isNull);
    },
  );

  test(
    'refresh and retry cannot rebase an uncertain original intent',
    () async {
      final draft = await open();
      fixture.failBeforeWrite = true;
      await edit.selectHelper(draft, after, confirm: accept);
      fixture.vision['base_url'] = 'https://external.invalid';
      fixture.failBeforeWrite = false;
      await edit.load();
      expect(
        await edit.retryHelper('vision', confirm: accept),
        HelperSaveOutcome.failed,
      );
      expect(fixture.posts, hasLength(1));
      expect(edit.pendingFor('vision')!.state, HelperChangeState.conflict);
    },
  );

  test(
    'retry confirmation does not permit a later conflict overwrite',
    () async {
      final draft = await open();
      fixture.failBeforeWrite = true;
      await edit.selectHelper(draft, after, confirm: accept);
      fixture.failBeforeWrite = false;
      final opened = Completer<void>(), consent = Completer<bool>();
      final result = edit.retryHelper(
        'vision',
        confirm: (question) {
          expect(question.kind, HelperConfirmationKind.retry);
          opened.complete();
          return consent.future;
        },
      );
      await opened.future;
      fixture.vision['reasoning_effort'] = 'medium';
      consent.complete(true);
      expect(await result, HelperSaveOutcome.failed);
      expect(fixture.posts, hasLength(1));
    },
  );

  test('expensive confirmation revalidates full opening assignment', () async {
    final draft = await open();
    fixture.requireCost = true;
    expect(
      await edit.selectHelper(
        draft,
        after,
        confirm: (question) async {
          expect(question.kind, HelperConfirmationKind.expensive);
          fixture.vision['base_url'] = 'https://external.invalid';
          return true;
        },
      ),
      HelperSaveOutcome.failed,
    );
    expect(fixture.posts, hasLength(1));
    expect(fixture.vision['model'], 'before');
  });

  test(
    'profile removal at final membership preflight prevents dispatch',
    () async {
      final draft = await open();
      fixture.exists = false;
      expect(
        await edit.selectHelper(draft, after, confirm: accept),
        HelperSaveOutcome.failed,
      );
      expect(fixture.posts, isEmpty);
    },
  );

  test('disposal during final membership preflight retires dispatch', () async {
    final draft = await open();
    fixture.membership = Completer<void>();
    final result = edit.selectHelper(draft, after, confirm: accept);
    await fixture.membershipEntered.future;
    // Avoid disposing twice in tearDown.
    final retired = edit;
    edit = ProfileModelDefaultsSession(fixture.server.profile('personal'));
    retired.dispose();
    fixture.membership!.complete();
    expect(await result, HelperSaveOutcome.retired);
    expect(fixture.posts, isEmpty);
  });

  test(
    'catalog finishing after a newer load cannot open a stale picker',
    () async {
      await edit.load();
      fixture.optionsGate = Completer<void>();
      final picker = edit.prepareHelper('vision');
      await fixture.optionsEntered.future;
      final held = fixture.optionsGate!;
      fixture.optionsGate = null;
      await edit.load();
      held.complete();
      expect(await picker, isNull);
      expect(fixture.posts, isEmpty);
    },
  );

  test(
    'reset consent retains all opening baselines and checks fresh membership',
    () async {
      await edit.load();
      expect(
        await edit.resetHelpers(
          confirm: (_) async {
            fixture.helpers.last['reasoning_effort'] = 'high';
            return true;
          },
        ),
        HelperSaveOutcome.failed,
      );
      expect(fixture.posts, isEmpty);
      expect(edit.pendingFor(null)!.state, HelperChangeState.conflict);
    },
  );

  test(
    'reset verifies credential absence and reconciles without automatic resend',
    () async {
      fixture.credentialPresent.add('vision');
      fixture.keepResetCredential = true;
      await edit.load();
      expect(
        await edit.resetHelpers(confirm: accept),
        HelperSaveOutcome.failed,
      );
      expect(edit.pendingFor(null)!.state, HelperChangeState.uncertain);
      expect(fixture.posts, hasLength(1));
      fixture.credentialPresent.clear();
      expect(
        await edit.retryHelper(
          null,
          confirm: (_) async => fail('No second reset'),
        ),
        HelperSaveOutcome.saved,
      );
      expect(fixture.posts, hasLength(1));
      expect(
        edit.observation!.helpers.every(
          (row) => row.provider == 'auto' && row.reasoningEffort == null,
        ),
        isTrue,
      );
    },
  );

  test('older load cannot replace a command verified readback', () async {
    final draft = await open();
    final old = fixture.copy({'tasks': fixture.helpers});
    final held = Completer<Map<String, dynamic>>();
    fixture.nextAuxiliary = held;
    final loading = edit.load();
    await fixture.auxiliaryEntered.future;
    expect(
      await edit.selectHelper(draft, after, confirm: accept),
      HelperSaveOutcome.saved,
    );
    held.complete(old);
    await loading;
    expect(edit.observation!.helpers.first.model, 'after');
    expect(edit.loading, isFalse);
    expect(fixture.posts, hasLength(1));
  });

  test('held owned dispatch cannot send after route disposal', () async {
    final draft = await open();
    fixture.mutationGate = Completer<void>();
    final result = edit.selectHelper(draft, after, confirm: accept);
    await fixture.mutationEntered.future;
    final retired = edit;
    edit = ProfileModelDefaultsSession(fixture.server.profile('personal'));
    retired.dispose();
    fixture.mutationGate!.complete();
    expect(await result, HelperSaveOutcome.retired);
    expect(fixture.posts, isEmpty);
  });

  test(
    'deadline retires dispatch even while route and generation stay live',
    () async {
      final draft = await open();
      fixture.mutationGate = Completer<void>();
      fixture.timeoutMutation = true;
      final result = edit.selectHelper(draft, after, confirm: accept);
      await fixture.mutationEntered.future;
      expect(await result, HelperSaveOutcome.failed);
      expect(edit.busy, isFalse);
      expect(edit.pendingFor('vision')!.state, HelperChangeState.pending);
      fixture.mutationGate!.complete();
      await fixture.mutationExited.future;
      expect(fixture.posts, isEmpty);
      expect(fixture.vision['model'], 'before');
      fixture.timeoutMutation = false;
      fixture.mutationGate = null;
      expect(
        await edit.retryHelper('vision', confirm: accept),
        HelperSaveOutcome.saved,
      );
      expect(fixture.posts, hasLength(1));
    },
  );

  test(
    'confirmation owns authority without claiming active transfer work',
    () async {
      await edit.load();
      final consent = Completer<bool>(), entered = Completer<void>();
      final result = edit.resetHelpers(
        confirm: (_) {
          entered.complete();
          return consent.future;
        },
      );
      await entered.future;
      expect(edit.busy, isTrue);
      expect(edit.working, isFalse);
      expect(
        await edit.resetHelpers(confirm: accept),
        HelperSaveOutcome.retired,
      );
      expect(fixture.posts, isEmpty);
      consent.complete(false);
      expect(await result, HelperSaveOutcome.cancelled);
      expect(edit.busy, isFalse);
      expect(edit.working, isFalse);
    },
  );

  test(
    'removed catalog choice cannot be dispatched from an older picker',
    () async {
      final draft = await open();
      fixture.availableModels = ['before'];
      expect(
        await edit.selectHelper(draft, after, confirm: accept),
        HelperSaveOutcome.failed,
      );
      expect(fixture.posts, isEmpty);
      expect(edit.error, contains('no longer in the catalog'));
    },
  );

  test(
    'disposal during cost confirmation cannot dispatch confirmed retry',
    () async {
      final draft = await open();
      fixture.requireCost = true;
      final entered = Completer<void>(), consent = Completer<bool>();
      final result = edit.selectHelper(
        draft,
        after,
        confirm: (_) {
          entered.complete();
          return consent.future;
        },
      );
      await entered.future;
      final retired = edit;
      edit = ProfileModelDefaultsSession(fixture.server.profile('personal'));
      retired.dispose();
      consent.complete(true);
      expect(await result, HelperSaveOutcome.retired);
      expect(fixture.posts, hasLength(1));
      expect(fixture.vision['model'], 'before');
    },
  );
}
