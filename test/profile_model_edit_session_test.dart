import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/models/hermes_profile.dart';
import 'package:wing/core/services/profile_gateway.dart';
import 'package:wing/core/services/profile_model_edit_session.dart';
import 'package:wing/core/services/profiles_repository.dart';

void main() {
  late String model;
  late String provider;
  late List<Map<String, dynamic>> posts;
  late ProfileModelEditSession edit;
  Completer<ProfileDiscovery>? discovery;
  Completer<Map<String, dynamic>>? readback;
  Completer<void>? readbackEntered;
  Completer<Map<String, dynamic>>? preflightRead;
  late bool profileAvailable;
  Completer<void>? optionsRead;
  Completer<void>? optionsEntered;
  late List<String> optionsModels;
  late bool confirmation;
  late bool mismatch;
  const profiles = ProfileDiscovery(
    profiles: [HermesProfile(name: 'work')],
    currentName: 'work',
    activeName: 'work',
  );

  setUp(() {
    model = 'before';
    provider = 'p';
    posts = [];
    confirmation = false;
    mismatch = false;
    discovery = null;
    readback = null;
    readbackEntered = null;
    preflightRead = null;
    profileAvailable = true;
    optionsRead = null;
    optionsEntered = null;
    optionsModels = ['before', 'after'];
    edit = ProfileModelEditSession(
      ProfileGateway(
        scope: WorkspaceScope(
          connectionId: 'test',
          connectionIdentity: 'model-owner',
          profileName: 'work',
        ),
        get: (path, query) async {
          expect(query['profile'], 'work');
          if (path == 'model/info') {
            if (preflightRead != null) return preflightRead!.future;
            if (posts.isNotEmpty && readback != null) {
              readbackEntered?.complete();
              return readback!.future;
            }
            return {'provider': provider, 'model': model};
          }
          if (path == 'model/options') {
            final capturedModels = List<String>.of(optionsModels);
            final pending = optionsRead;
            if (pending != null) {
              optionsEntered?.complete();
              await pending.future;
            }
            return {
              'providers': [
                {
                  'slug': 'p',
                  'name': 'Provider',
                  'models': [
                    if (capturedModels.contains('before')) 'before',
                    if (capturedModels.contains('after')) 'after',
                    if (capturedModels.contains('new-choice')) 'new-choice',
                    if (capturedModels.contains('stale-choice')) 'stale-choice',
                  ],
                },
              ],
            };
          }
          throw StateError(path);
        },
        ownedPost: (path, body, canDispatch, onDispatched) async {
          if (!canDispatch()) throw StateError('Retired model write');
          onDispatched();
          expect(path, 'model/set?profile=work');
          posts.add(Map.of(body));
          if (confirmation && body['confirm_expensive_model'] != true) {
            return {
              'ok': false,
              'confirm_required': true,
              'confirm_message': 'Confirm cost',
            };
          }
          if (!mismatch) {
            model = body['model'] as String;
            provider = body['provider'] as String;
          }
          return {'ok': true};
        },
        rpc: (_, _) async => {},
        discover: () async => discovery != null
            ? discovery!.future
            : profileAvailable
            ? profiles
            : const ProfileDiscovery(
                profiles: [],
                currentName: null,
                activeName: null,
              ),
      ),
    );
  });

  Future<void> choose() async {
    await edit.load();
    edit.select(edit.choices.last);
  }

  test(
    'a profile removed during model preflight cannot receive a write',
    () async {
      await choose();
      preflightRead = Completer<Map<String, dynamic>>();
      final saving = edit.save(confirm: (_) async => true);
      await Future<void>.delayed(Duration.zero);
      profileAvailable = false;
      preflightRead!.complete({'provider': 'p', 'model': 'before'});
      expect(await saving, ProfileModelSaveOutcome.failed);
      expect(posts, isEmpty);
      edit.dispose();
    },
  );

  test('an older catalog refresh cannot replace newer choices', () async {
    await edit.load();
    final oldResponse = Completer<void>();
    optionsRead = oldResponse;
    optionsEntered = Completer<void>();
    optionsModels = ['stale-choice'];
    final oldRefresh = edit.refreshChoices();
    final retired = expectLater(oldRefresh, throwsStateError);
    await optionsEntered!.future;
    optionsRead = null;
    optionsEntered = null;
    optionsModels = ['after', 'new-choice'];
    await edit.refreshChoices();
    oldResponse.complete();
    await retired;
    expect(edit.choices.map((choice) => choice.model), ['after', 'new-choice']);
    edit.dispose();
  });

  test(
    'automatic-provider changes remain part of the opening baseline',
    () async {
      provider = '';
      await choose();
      model = 'changed-automatic-model';
      expect(
        await edit.save(confirm: (_) async => true),
        ProfileModelSaveOutcome.failed,
      );
      expect(posts, isEmpty);
      expect(model, 'changed-automatic-model');
      expect(edit.error, contains('changed elsewhere'));
      edit.dispose();
    },
  );

  test(
    'typed owner preserves captured scope and verifies saved pair',
    () async {
      await choose();
      expect(
        await edit.save(confirm: (_) async => fail('Unexpected confirmation')),
        ProfileModelSaveOutcome.saved,
      );
      expect(posts.single, {
        'scope': 'main',
        'provider': 'p',
        'model': 'after',
      });
      expect(edit.dirty, isFalse);
      expect(edit.saving, isFalse);
      edit.dispose();
    },
  );

  Future<void> conflict({
    String remoteProvider = 'p',
    String remoteModel = 'remote',
  }) async {
    await choose();
    provider = remoteProvider;
    model = remoteModel;
    expect(
      await edit.save(confirm: (_) async => true),
      ProfileModelSaveOutcome.failed,
    );
    expect(posts, isEmpty);
    expect(edit.selected!.model, 'after');
    expect(edit.canReview, true);
  }

  test(
    'cancelled model review does not replace intent or rebase its opening pair',
    () async {
      await conflict();
      final review = (await edit.reviewPending())!;
      expect(review.current.provider, 'p');
      expect(review.current.model, 'remote');
      expect(review.wanted.model, 'after');
      expect(edit.cancelReview(review), ProfileModelReviewOutcome.cancelled);
      expect(edit.selected!.model, 'after');
      expect(edit.dirty, true);
      expect(
        await edit.save(confirm: (_) async => true),
        ProfileModelSaveOutcome.failed,
      );
      expect(posts, isEmpty);
      expect(
        edit.applyReviewed(review, ProfileModelReviewDecision.keepMine),
        ProfileModelReviewOutcome.retired,
      );
      edit.dispose();
    },
  );

  test(
    'Keep mine changes local baseline only and later saves the captured pair once',
    () async {
      await conflict();
      final review = (await edit.reviewPending())!;
      expect(
        edit.applyReviewed(review, ProfileModelReviewDecision.keepMine),
        ProfileModelReviewOutcome.applied,
      );
      expect(posts, isEmpty);
      expect(edit.selected!.model, 'after');
      expect(edit.dirty, true);
      expect(
        await edit.save(confirm: (_) async => true),
        ProfileModelSaveOutcome.saved,
      );
      expect(posts.single, {
        'scope': 'main',
        'provider': 'p',
        'model': 'after',
      });
      edit.dispose();
    },
  );

  test(
    'Use server preserves automatic-provider identity for the next edit preflight',
    () async {
      await conflict(remoteProvider: '', remoteModel: 'automatic-one');
      final review = (await edit.reviewPending())!;
      expect(review.current.provider, '');
      expect(review.current.model, 'automatic-one');
      expect(
        edit.applyReviewed(review, ProfileModelReviewDecision.useServer),
        ProfileModelReviewOutcome.applied,
      );
      expect(edit.selected, isNull);
      expect(edit.dirty, false);
      expect(posts, isEmpty);
      edit.select(edit.choices.last);
      model = 'automatic-two';
      expect(
        await edit.save(confirm: (_) async => true),
        ProfileModelSaveOutcome.failed,
      );
      expect(posts, isEmpty);
      expect(model, 'automatic-two');
      expect(edit.selected!.model, 'after');
      edit.dispose();
    },
  );

  test(
    'a second remote change after review still refuses before dispatch',
    () async {
      await conflict();
      final review = (await edit.reviewPending())!;
      model = 'remote-two';
      expect(
        edit.applyReviewed(review, ProfileModelReviewDecision.keepMine),
        ProfileModelReviewOutcome.applied,
      );
      expect(
        await edit.save(confirm: (_) async => true),
        ProfileModelSaveOutcome.failed,
      );
      expect(posts, isEmpty);
      expect(edit.selected!.model, 'after');
      final fresh = (await edit.reviewPending())!;
      expect(fresh.current.model, 'remote-two');
      expect(
        edit.applyReviewed(fresh, ProfileModelReviewDecision.keepMine),
        ProfileModelReviewOutcome.applied,
      );
      expect(
        await edit.save(confirm: (_) async => true),
        ProfileModelSaveOutcome.saved,
      );
      expect(posts, hasLength(1));
      edit.dispose();
    },
  );

  test(
    'another review and a newer selected choice retire older tickets',
    () async {
      await conflict();
      final older = (await edit.reviewPending())!;
      model = 'remote-two';
      final latest = (await edit.reviewPending())!;
      expect(
        edit.applyReviewed(older, ProfileModelReviewDecision.keepMine),
        ProfileModelReviewOutcome.retired,
      );
      edit.select(edit.choices.first);
      expect(
        edit.applyReviewed(latest, ProfileModelReviewDecision.useServer),
        ProfileModelReviewOutcome.retired,
      );
      expect(edit.selected!.model, 'before');
      expect(posts, isEmpty);
      edit.dispose();
    },
  );

  for (final retire in ['selection', 'disposal']) {
    test(
      'held model review is retired by $retire without late publication',
      () async {
        await conflict();
        preflightRead = Completer<Map<String, dynamic>>();
        final pending = edit.reviewPending();
        expect(edit.reviewing, true);
        var changes = 0;
        edit.addListener(() => changes++);
        if (retire == 'disposal') {
          edit.dispose();
        } else {
          edit.select(edit.choices.first);
        }
        final beforeRelease = changes;
        preflightRead!.complete({'provider': 'p', 'model': 'remote'});
        expect(await pending, isNull);
        expect(changes, beforeRelease);
        expect(posts, isEmpty);
        if (retire != 'disposal') {
          expect(edit.selected!.model, 'before');
          expect(edit.reviewing, false);
          edit.dispose();
        }
      },
    );
  }

  test(
    'review cannot survive profile removal during held current-model read',
    () async {
      await conflict();
      preflightRead = Completer<Map<String, dynamic>>();
      final pending = edit.reviewPending();
      profileAvailable = false;
      preflightRead!.complete({'provider': 'p', 'model': 'remote'});
      expect(await pending, isNull);
      expect(edit.selected!.model, 'after');
      expect(edit.dirty, true);
      expect(edit.error, isNotNull);
      expect(posts, isEmpty);
      expect(edit.reviewing, false);
      edit.dispose();
    },
  );

  test(
    'invalid review observation keeps pending selection and cannot establish a baseline',
    () async {
      await conflict();
      preflightRead = Completer<Map<String, dynamic>>();
      final pending = edit.reviewPending();
      preflightRead!.complete({'provider': 'p', 'model': false});
      expect(await pending, isNull);
      expect(edit.selected!.model, 'after');
      expect(edit.dirty, true);
      expect(posts, isEmpty);
      preflightRead = null;
      expect(
        await edit.save(confirm: (_) async => true),
        ProfileModelSaveOutcome.failed,
      );
      expect(posts, isEmpty);
      edit.dispose();
    },
  );

  test(
    'dirty loading retains wanted choice and the opening conflict baseline',
    () async {
      await choose();
      model = 'remote';
      await edit.load();
      expect(edit.selected!.model, 'after');
      expect(edit.dirty, true);
      expect(edit.canReview, true);
      expect(
        await edit.save(confirm: (_) async => true),
        ProfileModelSaveOutcome.failed,
      );
      expect(posts, isEmpty);
      edit.dispose();
    },
  );

  test(
    'confirmation still rechecks the reviewed baseline before an accepted retry',
    () async {
      await conflict();
      final review = (await edit.reviewPending())!;
      expect(
        edit.applyReviewed(review, ProfileModelReviewDecision.keepMine),
        ProfileModelReviewOutcome.applied,
      );
      confirmation = true;
      expect(
        await edit.save(
          confirm: (_) async {
            model = 'remote-during-confirmation';
            return true;
          },
        ),
        ProfileModelSaveOutcome.failed,
      );
      expect(posts, hasLength(1));
      expect(posts.single.containsKey('confirm_expensive_model'), false);
      expect(model, 'remote-during-confirmation');
      expect(edit.selected!.model, 'after');
      expect(edit.canReview, true);
      edit.dispose();
    },
  );

  test(
    'disposal during profile validation prevents initial dispatch',
    () async {
      await choose();
      discovery = Completer<ProfileDiscovery>();
      final result = edit.save(confirm: (_) async => true);
      await Future<void>.delayed(Duration.zero);
      edit.dispose();
      discovery!.complete(profiles);
      expect(await result, ProfileModelSaveOutcome.retired);
      expect(posts, isEmpty);
    },
  );

  test(
    'disposal while confirmation is pending prevents confirmed retry',
    () async {
      await choose();
      confirmation = true;
      final accepted = Completer<bool>();
      final opened = Completer<void>();
      final result = edit.save(
        confirm: (message) {
          expect(message, 'Confirm cost');
          opened.complete();
          return accepted.future;
        },
      );
      await opened.future;
      edit.dispose();
      accepted.complete(true);
      expect(await result, ProfileModelSaveOutcome.retired);
      expect(posts, hasLength(1));
    },
  );

  test('denial preserves selected edit without retry or success', () async {
    await choose();
    confirmation = true;
    expect(
      await edit.save(confirm: (_) async => false),
      ProfileModelSaveOutcome.cancelled,
    );
    expect(posts, hasLength(1));
    expect(edit.dirty, isTrue);
    expect(edit.notice, 'Model change cancelled.');
    edit.dispose();
  });

  test('mismatched readback keeps edit and uncertainty visible', () async {
    await choose();
    mismatch = true;
    expect(
      await edit.save(confirm: (_) async => true),
      ProfileModelSaveOutcome.failed,
    );
    expect(edit.dirty, isTrue);
    expect(edit.error, contains('could not be confirmed'));
    expect(posts, hasLength(1));
    edit.dispose();
  });

  test(
    'late successful readback cannot publish after route retirement',
    () async {
      await choose();
      readback = Completer<Map<String, dynamic>>();
      readbackEntered = Completer<void>();
      final result = edit.save(confirm: (_) async => true);
      await readbackEntered!.future;
      edit.dispose();
      readback!.complete({'provider': 'p', 'model': 'after'});
      expect(await result, ProfileModelSaveOutcome.retired);
      expect(posts, hasLength(1));
    },
  );
  test(
    'external change during confirmation prevents overwriting that selection',
    () async {
      await choose();
      confirmation = true;
      final result = await edit.save(
        confirm: (_) async {
          model = 'external-choice';
          return true;
        },
      );
      expect(result, ProfileModelSaveOutcome.failed);
      expect(posts, hasLength(1));
      expect(model, 'external-choice');
      expect(edit.error, contains('changed elsewhere'));
      expect(edit.dirty, isTrue);
      edit.dispose();
    },
  );
}
