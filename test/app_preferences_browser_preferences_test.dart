import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:wing/core/models/chat_browser_preferences.dart';
import 'package:wing/core/models/chat_list_view.dart';
import 'package:wing/core/services/app_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppPreferences owner;
  late SharedPreferences preferences;
  late _BrowserStorage platform;
  late SharedPreferencesStorePlatform previousPlatform;
  const identity = 'browser';
  final key = ChatBrowserPreferencesCodec.storageKey(identity);

  Future<void> open({Object? raw}) async {
    SharedPreferences.resetStatic();
    platform = _BrowserStorage(raw == null ? {} : {'flutter.$key': raw});
    SharedPreferencesStorePlatform.instance = platform;
    preferences = await SharedPreferences.getInstance();
    owner = AppPreferences(preferences);
  }

  setUp(() {
    previousPlatform = SharedPreferencesStorePlatform.instance;
  });
  tearDown(() {
    if (!platform.release.isCompleted) platform.release.complete();
    if (!platform.reloadRelease.isCompleted) platform.reloadRelease.complete();
    owner.dispose();
    SharedPreferences.resetStatic();
    SharedPreferencesStorePlatform.instance = previousPlatform;
  });

  BrowserPreferenceIntent profile(String name) =>
      BrowserPreferenceIntent.toggle(BrowserFilter.profile, name);

  test(
    'absence declares defaults but malformed presence is not healed',
    () async {
      await open(raw: '{');
      final channel = owner.browserPreferencesFor(identity);
      expect(channel.value.validity, BrowserPreferencesValidity.invalid);
      expect(channel.value.confirmed, isNull);
      expect(channel.value.display, isNull);
      expect(channel.value.canChoose, isFalse);
      expect(
        await owner.chooseBrowserPreferences(identity, profile('work')),
        BrowserPreferencesSaveOutcome.blocked,
      );
      expect(platform.writes, isEmpty);
      expect(preferences.get(key), '{');
      expect(
        await owner.chooseBrowserPreferences(
          identity,
          const BrowserPreferenceIntent.reset(),
        ),
        BrowserPreferencesSaveOutcome.saved,
      );
      expect(channel.value.display, ChatBrowserPreferences.fresh());
      await owner.reload();
      expect(
        ChatBrowserPreferencesCodec.decode(preferences.get(key)),
        ChatBrowserPreferences.fresh(),
      );
    },
  );

  test('same-connection intents compose in physical FIFO order', () async {
    await open();
    platform.holdNext = true;
    final channel = owner.browserPreferencesFor(identity);
    var generalNotifications = 0;
    owner.state.addListener(() {
      generalNotifications++;
    });
    final first = owner.chooseBrowserPreferences(identity, profile('personal'));
    await platform.entered.future;
    final second = owner.chooseBrowserPreferences(identity, profile('work'));
    expect(platform.writes.length, 1);
    expect(channel.value.confirmed!.profiles, isEmpty);
    expect(channel.value.display!.profiles, {'personal', 'work'});
    platform.release.complete();
    expect(await first, BrowserPreferencesSaveOutcome.saved);
    expect(await second, BrowserPreferencesSaveOutcome.saved);
    expect(platform.writes.map((value) => jsonDecode(value)['profile']), [
      ['personal'],
      ['personal', 'work'],
    ]);
    expect(generalNotifications, 0);
    await owner.reload();
    expect(channel.value.confirmed!.profiles, {'personal', 'work'});
    expect(channel.value.busy, isFalse);
  });

  test(
    'reentrant pending listener admits after its triggering command',
    () async {
      await open();
      final channel = owner.browserPreferencesFor(identity);
      Future<BrowserPreferencesSaveOutcome>? reentrant;
      channel.addListener(() {
        if (channel.value.busy && reentrant == null) {
          // Mark admission before another synchronous publication can reenter.
          reentrant = Future.value(BrowserPreferencesSaveOutcome.unchanged);
          reentrant = owner.chooseBrowserPreferences(identity, profile('work'));
        }
      });
      expect(
        await owner.chooseBrowserPreferences(identity, profile('personal')),
        BrowserPreferencesSaveOutcome.saved,
      );
      expect(await reentrant, BrowserPreferencesSaveOutcome.saved);
      expect(platform.writes.map((value) => jsonDecode(value)['profile']), [
        ['personal'],
        ['personal', 'work'],
      ]);
      expect(channel.value.display!.profiles, {'personal', 'work'});
    },
  );

  for (final throwing in [false, true]) {
    test(
      'failed ACK restores absence and retracts pending choice (throw $throwing)',
      () async {
        await open();
        platform.failNext = true;
        platform.throwFailure = throwing;
        final channel = owner.browserPreferencesFor(identity);
        expect(
          await owner.chooseBrowserPreferences(identity, profile('personal')),
          BrowserPreferencesSaveOutcome.failedRestored,
        );
        expect(preferences.containsKey(key), isFalse);
        expect((await platform.getAll()).containsKey('flutter.$key'), isFalse);
        expect(channel.value.display!.profiles, isEmpty);
        expect(channel.value.error, isNotNull);
        expect(channel.value.busy, isFalse);
        expect(
          await owner.chooseBrowserPreferences(identity, profile('work')),
          BrowserPreferencesSaveOutcome.saved,
        );
        expect(channel.value.confirmed!.profiles, {'work'});
      },
    );
  }

  test(
    'unconfirmed rollback blocks choices until a fresh observation',
    () async {
      await open();
      platform.failNext = true;
      platform.partialFailure = true;
      platform.failRemove = true;
      final channel = owner.browserPreferencesFor(identity);
      expect(
        await owner.chooseBrowserPreferences(identity, profile('personal')),
        BrowserPreferencesSaveOutcome.failedUnverified,
      );
      expect(
        jsonDecode(
          (await platform.getAll())['flutter.$key'] as String,
        )['profile'],
        ['personal'],
        reason: 'false ACK may have actual effects',
      );
      expect(channel.value.validity, BrowserPreferencesValidity.unverified);
      expect(channel.value.display, isNull);
      final writeCount = platform.writes.length;
      expect(
        await owner.chooseBrowserPreferences(identity, profile('work')),
        BrowserPreferencesSaveOutcome.blocked,
      );
      expect(platform.writes.length, writeCount);
      platform.failReload = true;
      await expectLater(owner.reload(), throwsStateError);
      expect(channel.value.validity, BrowserPreferencesValidity.unverified);
      platform.failReload = false;
      await owner.reload();
      expect(channel.value.validity, BrowserPreferencesValidity.valid);
      expect(channel.value.confirmed!.profiles, {'personal'});
      expect(channel.value.error, isNull);
    },
  );

  test('malformed refresh retains history without authorizing it', () async {
    await open();
    final channel = owner.browserPreferencesFor(identity);
    await owner.chooseBrowserPreferences(identity, profile('personal'));
    final before = channel.value.confirmed;
    await platform.replace(key, 7);
    await owner.reload();
    expect(channel.value.confirmed, same(before));
    expect(channel.value.validity, BrowserPreferencesValidity.invalid);
    expect(channel.value.display, isNull);
    expect(
      await owner.chooseBrowserPreferences(
        identity,
        const BrowserPreferenceIntent.reset(),
      ),
      BrowserPreferencesSaveOutcome.saved,
    );
    expect(channel.value.confirmed, ChatBrowserPreferences.fresh());
  });

  test(
    'held shared reload publishes browser busy without another queue',
    () async {
      await open();
      final channel = owner.browserPreferencesFor(identity);
      platform.holdReload = true;
      final reload = owner.reload();
      await platform.reloadEntered.future;
      expect(channel.value.busy, isTrue);
      expect(platform.writes, isEmpty);
      platform.reloadRelease.complete();
      await reload;
      expect(channel.value.busy, isFalse);
      expect(channel.value.validity, BrowserPreferencesValidity.valid);
    },
  );

  test(
    'fresh reload observes actual effects before queued intent display',
    () async {
      await open();
      platform.failNext = true;
      platform.partialFailure = true;
      platform.failRemove = true;
      final channel = owner.browserPreferencesFor(identity);
      expect(
        await owner.chooseBrowserPreferences(identity, profile('personal')),
        BrowserPreferencesSaveOutcome.failedUnverified,
      );
      expect(
        jsonDecode(
          (await platform.getAll())['flutter.$key'] as String,
        )['profile'],
        ['personal'],
      );
      platform.holdReload = true;
      final reload = owner.reload();
      await platform.reloadEntered.future;
      final queued = owner.chooseBrowserPreferences(identity, profile('work'));
      final confirmedWhileBusy = <Set<String>>[];
      channel.addListener(() {
        final fact = channel.value;
        if (fact.validity == BrowserPreferencesValidity.valid && fact.busy) {
          confirmedWhileBusy.add(fact.confirmed!.profiles);
        }
      });
      platform.reloadRelease.complete();
      await reload;
      expect(await queued, BrowserPreferencesSaveOutcome.saved);
      expect(confirmedWhileBusy, isNotEmpty);
      expect(
        confirmedWhileBusy.every((profiles) => profiles.contains('personal')),
        isTrue,
      );
      expect(channel.value.confirmed!.profiles, {'personal', 'work'});
      await preferences.reload();
      expect(
        ChatBrowserPreferencesCodec.decode(preferences.get(key)).profiles,
        {'personal', 'work'},
      );
    },
  );

  test('reset failure restores the exact malformed value', () async {
    await open(raw: 7);
    final channel = owner.browserPreferencesFor(identity);
    platform.failNext = true;
    expect(
      await owner.chooseBrowserPreferences(
        identity,
        const BrowserPreferenceIntent.reset(),
      ),
      BrowserPreferencesSaveOutcome.failedRestored,
    );
    expect(preferences.get(key), 7);
    expect((await platform.getAll())['flutter.$key'], 7);
    expect(channel.value.validity, BrowserPreferencesValidity.invalid);
    expect(channel.value.display, isNull);
  });

  test('identities share ordering and keep separate confirmed facts', () async {
    await open();
    final a = owner.browserPreferencesFor(identity);
    final b = owner.browserPreferencesFor('other');
    await owner.chooseBrowserPreferences(identity, profile('personal'));
    await owner.chooseBrowserPreferences(
      'other',
      const BrowserPreferenceIntent.ordering(ChatOrdering.created),
    );
    expect(a.value.confirmed!.profiles, {'personal'});
    expect(b.value.confirmed!.profiles, isEmpty);
    expect(b.value.confirmed!.ordering, ChatOrdering.created);
    expect(platform.keys, ['flutter.$key', 'flutter.chat_list_target_other']);
  });

  test(
    'retirement settles dispatched write and refuses queued write',
    () async {
      await open();
      platform.holdNext = true;
      owner.browserPreferencesFor(identity);
      final admitted = owner.chooseBrowserPreferences(
        identity,
        profile('personal'),
      );
      await platform.entered.future;
      final queued = owner.chooseBrowserPreferences(identity, profile('work'));
      owner.dispose();
      platform.release.complete();
      expect(await admitted, BrowserPreferencesSaveOutcome.saved);
      expect(await queued, BrowserPreferencesSaveOutcome.retired);
      expect(platform.writes.length, 1);
      await preferences.reload();
      expect(
        ChatBrowserPreferencesCodec.decode(preferences.get(key)).profiles,
        {'personal'},
      );
      expect(
        await owner.chooseBrowserPreferences(identity, profile('work')),
        BrowserPreferencesSaveOutcome.retired,
      );
    },
  );
}

class _BrowserStorage extends InMemorySharedPreferencesStore {
  _BrowserStorage(super.data) : super.withData();
  final entered = Completer<void>();
  final release = Completer<void>();
  final reloadEntered = Completer<void>();
  final reloadRelease = Completer<void>();
  final writes = <String>[];
  final keys = <String>[];
  bool holdNext = false;
  bool failNext = false;
  bool throwFailure = false;
  bool partialFailure = false;
  bool failRemove = false;
  bool failReload = false;
  bool holdReload = false;

  Future<bool> replace(String key, Object value) =>
      super.setValue('String', 'flutter.$key', value);

  @override
  Future<Map<String, Object>> getAll() async {
    if (failReload) throw StateError('Controlled reload failure');
    if (holdReload) {
      holdReload = false;
      reloadEntered.complete();
      await reloadRelease.future;
    }
    return super.getAll();
  }

  @override
  Future<bool> remove(String key) {
    if (failRemove) return Future.value(false);
    return super.remove(key);
  }

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    if (key.startsWith('flutter.chat_list_target_') && value is String) {
      writes.add(value);
      keys.add(key);
      if (holdNext) {
        holdNext = false;
        entered.complete();
        await release.future;
      }
      if (failNext) {
        failNext = false;
        if (partialFailure) await super.setValue(valueType, key, value);
        if (throwFailure) throw StateError('Controlled write failure');
        return false;
      }
    }
    return super.setValue(valueType, key, value);
  }
}
