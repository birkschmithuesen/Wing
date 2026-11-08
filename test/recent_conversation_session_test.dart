import 'package:wing/core/services/recent_conversation_snapshots.dart';
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/models/hermes_profile.dart';
import 'package:wing/core/models/bots.dart';
import 'package:wing/core/models/profile_session_key.dart';
import 'package:wing/core/models/recent_conversation.dart';
import 'package:wing/core/models/transcript_reading.dart';
import 'package:wing/core/services/recent_conversation_session.dart';
import 'package:wing/core/services/ws_client.dart';

final _scope = WorkspaceScope(
  connectionId: 'home',
  connectionIdentity: 'owner',
  profileName: 'personal',
);
RecentConversationEntry _entry(int index) => RecentConversationEntry.chat(
  key: ProfileSessionKey(_scope, '$index'),
  title: 'Chat $index',
  unread: false,
);
RecentConversationPreview _preview(RecentConversationEntry entry) =>
    RecentConversationPreview(
      entry: entry,
      reading: TranscriptReadingSnapshot(
        messages: const [],
        historySessionId: entry.key.chat!.sessionId,
      ),
      draft: '',
      scopeLabel: 'personal',
    );

class _Source extends ChangeNotifier implements RecentConversationSource {
  @override
  final snapshots = RecentConversationSnapshots();
  @override
  void dispose() {
    snapshots.dispose();
    super.dispose();
  }

  @override
  void setVisible(bool visible) {}
  @override
  bool current = true;
  @override
  bool opensRoute(RecentConversationKey key) => key.group != null;
  @override
  RecentConversationKey? selected;
  final opens = <RecentConversationKey>[];
  final reads = <RecentConversationKey, Completer<RecentConversationPreview>>{};
  Completer<void>? heldOpen;
  bool failOpen = false, cached = false;
  Object? openFailure;
  final denied = <RecentConversationKey>{};
  Completer<RecentConversationCatalog>? catalogRead;
  int catalogReads = 0;
  List<RecentConversationEntry> currentEntries = List.generate(8, _entry);
  @override
  RecentConversationCatalog get catalog =>
      RecentConversationCatalog(entries: currentEntries, error: null);
  @override
  Future<RecentConversationCatalog> loadRecents({required bool refresh}) {
    catalogReads++;
    return catalogRead?.future ??
        Future.value(
          RecentConversationCatalog(entries: currentEntries, error: null),
        );
  }

  @override
  bool admits(RecentConversationKey key) => current && !denied.contains(key);
  @override
  RecentConversationAppearance appearanceFor(RecentConversationKey key) =>
      const RecentConversationAppearance();
  @override
  Future<void> prepareAppearances(
    Iterable<RecentConversationKey> keys,
    bool Function() canRead,
  ) async {}

  @override
  Object previewRevision(RecentConversationKey key) => revisions[key] ?? 0;
  final revisions = <RecentConversationKey, int>{};
  @override
  RecentConversationPreview? cachedPreview(RecentConversationEntry entry) =>
      cached ? _preview(entry) : null;
  @override
  Future<RecentConversationPreview> loadPreview(
    RecentConversationEntry entry,
    bool Function() canRead,
  ) {
    final read = Completer<RecentConversationPreview>();
    reads[entry.key] = read;
    return read.future;
  }

  @override
  Future<void> open(
    RecentConversationKey key,
    bool Function() isCurrent,
  ) async {
    opens.add(key);
    await heldOpen?.future;
    if (!isCurrent()) return;
    if (openFailure case final failure?) throw failure;
    if (failOpen) throw StateError('Offline');
    selected = key;
    notifyListeners();
  }
}

void main() {
  late _Source source;
  late ValueNotifier<ChatNoticeActivity?> activity;
  late RecentConversationSession session;
  var activityRequests = 0;
  setUp(() {
    activityRequests = 0;
    source = _Source();
    activity = ValueNotifier(null);
    session = RecentConversationSession.fromRecents(
      entries: List.generate(8, _entry),
      source: source,
      activity: activity,
    );
  });
  tearDown(() {
    session.dispose();
    source.dispose();
    activity.dispose();
  });

  void enterChat() {
    session.dispose();
    source.selected = _entry(0).key;
    session = RecentConversationSession.fromChat(
      chat: _entry(0),
      source: source,
      activity: () {
        activityRequests++;
        return activity;
      },
    );
  }

  test(
    'dormant chat adopts selection without opening, reading or cueing',
    () async {
      enterChat();
      expect(session.selected, source.selected);
      expect(session.modeEnabled, isFalse);
      expect(session.entries, hasLength(1));
      session.setInteractive(true, origin: source.selected);
      activity.value = ChatNoticeActivity(
        key: _entry(1).key,
        kind: ConversationActivityKind.reply,
        identity: 'old',
        sequence: 1,
      );
      expect(source.opens, isEmpty);
      expect(source.reads, isEmpty);
      expect(source.catalogReads, 0);
      expect(activityRequests, 0);
      expect(session.nudges.value, isNull);
    },
  );

  test(
    'activation admits known neighbors before a held refresh emits anything',
    () async {
      enterChat();
      source.catalogRead = Completer<RecentConversationCatalog>();
      session.activate();
      expect(session.catalogLoading, isTrue);
      expect(
        session.entries.map((entry) => entry.key),
        source.currentEntries.map((entry) => entry.key),
      );
      expect(source.reads, isEmpty);
      expect(source.opens, isEmpty);
      source.catalogRead!.complete(source.catalog);
      await Future<void>.delayed(Duration.zero);
      expect(session.catalogLoading, isFalse);
    },
  );

  test(
    'activation loads once and defers membership until motion settles',
    () async {
      enterChat();
      source.catalogRead = Completer();
      session.setMembershipPaused(true);
      session.activate();
      session.activate();
      expect(session.modeEnabled, isTrue);
      expect(source.catalogReads, 1);
      expect(activityRequests, 1);
      expect(session.catalogLoading, isTrue);
      source.catalogRead!.complete(
        RecentConversationCatalog(
          entries: [_entry(1), _entry(0), _entry(2)],
          error: null,
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(session.entries, hasLength(1));
      expect(session.catalogLoading, isTrue);
      session.setMembershipPaused(false);
      expect(session.entries.map((entry) => entry.key), [
        _entry(1).key,
        _entry(0).key,
        _entry(2).key,
      ]);
      expect(session.catalogLoading, isFalse);
      expect(source.opens, isEmpty);
    },
  );

  test(
    'empty catalog retains current card and recovery restores canonical order',
    () async {
      enterChat();
      source.currentEntries = [];
      source.catalogRead = Completer();
      session.activate();
      source.catalogRead!.complete(
        RecentConversationCatalog(entries: const [], error: null),
      );
      await Future<void>.delayed(Duration.zero);
      expect(session.entries, hasLength(1));
      expect(session.catalogError, isNull);
      source.catalogRead = Completer();
      session.retryCatalog();
      session.retryCatalog();
      expect(source.catalogReads, 2);
      source.catalogRead!.complete(
        RecentConversationCatalog(
          entries: [_entry(1)],
          error: 'A profile is offline.',
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(session.entries.map((entry) => entry.key), [
        _entry(1).key,
        _entry(0).key,
      ]);
      expect(session.catalogError, isNotNull);
      source.catalogRead = Completer();
      session.retryCatalog();
      source.catalogRead!.complete(
        RecentConversationCatalog(
          entries: [_entry(2), _entry(1), _entry(0)],
          error: null,
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(session.entries.map((entry) => entry.key), [
        _entry(2).key,
        _entry(1).key,
        _entry(0).key,
      ]);
      expect(session.catalogError, isNull);
    },
  );

  testWidgets(
    'catalog deadline retains the current chat and fences late results',
    (tester) async {
      enterChat();
      source.currentEntries = [];
      source.catalogRead = Completer();
      session.activate();
      await tester.pump(const Duration(seconds: 15));
      expect(session.catalogLoading, isFalse);
      expect(session.catalogError, isNotNull);
      expect(session.entries, hasLength(1));
      source.catalogRead!.complete(
        RecentConversationCatalog(entries: [_entry(1)], error: null),
      );
      await tester.pump();
      expect(session.entries, hasLength(1));
      source.catalogRead = null;
      source.currentEntries = List.generate(8, _entry);
      session.retryCatalog();
      await tester.pump();
      expect(session.catalogError, isNull);
      expect(session.entries, hasLength(8));
    },
  );

  test('retirement fences a held catalog and its failure', () async {
    enterChat();
    source.currentEntries = [];
    source.catalogRead = Completer();
    session.activate();
    source.selected = _entry(7).key;
    source.notifyListeners();
    expect(session.active, isFalse);
    source.catalogRead!.completeError(StateError('late offline failure'));
    await Future<void>.delayed(Duration.zero);
    expect(session.entries, hasLength(1));
    expect(session.catalogError, isNull);
  });

  testWidgets(
    'progressive neighbors defer during motion and survive a refresh timeout',
    (tester) async {
      enterChat();
      source.currentEntries = [];
      source.catalogRead = Completer<RecentConversationCatalog>();
      session.activate();
      session.setMembershipPaused(true);
      source.currentEntries = [_entry(2), _entry(0)];
      source.notifyListeners();
      expect(session.entries, hasLength(1));
      source.currentEntries = [_entry(1), _entry(0), _entry(2)];
      source.notifyListeners();
      session.setMembershipPaused(false);
      final ready = session.entries;
      expect(ready.map((entry) => entry.key), [
        _entry(1).key,
        _entry(0).key,
        _entry(2).key,
      ]);
      expect(session.selected, _entry(0).key);
      expect(session.catalogLoading, isTrue);
      await tester.pump(const Duration(seconds: 15));
      expect(session.catalogLoading, isFalse);
      expect(session.catalogError, isNotNull);
      expect(
        session.entries.map((entry) => entry.key),
        ready.map((entry) => entry.key),
      );
      source.catalogRead!.complete(
        RecentConversationCatalog(entries: [_entry(7)], error: null),
      );
      await tester.pump();
      expect(
        session.entries.map((entry) => entry.key),
        ready.map((entry) => entry.key),
      );
      expect(source.reads, isEmpty);
      expect(source.opens, isEmpty);
    },
  );

  test(
    'canonical updates settle by identity and every entry point refreshes',
    () async {
      await session.select(_entry(2).key);
      session.setMembershipPaused(true);
      source.currentEntries = [_entry(3), _entry(2), _entry(0)];
      source.notifyListeners();
      expect(session.entries, hasLength(8));
      source.currentEntries = [_entry(0), _entry(3), _entry(2)];
      source.notifyListeners();
      session.setMembershipPaused(false);
      expect(session.entries.map((entry) => entry.key), [
        _entry(0).key,
        _entry(3).key,
        _entry(2).key,
      ]);
      expect(session.selected, _entry(2).key);
      expect(session.selectedIndex, 2);
      session.activate();
      await Future<void>.delayed(Duration.zero);
      expect(source.catalogReads, 1);
      session.activate();
      await Future<void>.delayed(Duration.zero);
      expect(source.catalogReads, 2);
    },
  );

  test('immutable scoped membership wraps both ends', () {
    expect(session.entryAt(-1).key, _entry(7).key);
    expect(session.entryAt(8).key, _entry(0).key);
    expect(() => session.entries.clear(), throwsUnsupportedError);
    final other = ProfileSessionKey(
      WorkspaceScope(
        connectionId: 'home',
        connectionIdentity: 'different',
        profileName: 'personal',
      ),
      '1',
    );
    expect(
      recentConversationDirection(
        session.entries,
        _entry(0).key,
        RecentConversationKey.chat(other),
      ),
      isNull,
    );
    expect(
      recentConversationDirection(
        session.entries,
        _entry(0).key,
        _entry(7).key,
      ),
      ConversationDirection.left,
    );
    expect(
      recentConversationDirection(
        session.entries,
        _entry(0).key,
        _entry(4).key,
      ),
      ConversationDirection.right,
    );
  });

  test(
    'bounds physical preview reads during rapid circular browsing',
    () async {
      session.prepare(session.keysAround(0, limit: 3));
      expect(source.reads, hasLength(3));
      session.prepare(session.keysAround(4, limit: 3));
      session.prepare(session.keysAround(5, limit: 3));
      expect(source.reads, hasLength(3));
      expect(source.opens, isEmpty);
      final old = source.reads.keys.toList();
      for (final key in old) {
        source.reads[key]!.complete(
          _preview(_entry(int.parse(key.chat!.sessionId))),
        );
      }
      await Future<void>.delayed(Duration.zero);
      expect(source.reads.keys.toSet(), {
        ...old,
        _entry(4).key,
        _entry(5).key,
        _entry(6).key,
      });
      expect(session.cardAt(0).preview, isNull);
      expect(source.opens, isEmpty);
      source.reads[_entry(5).key]!.complete(_preview(_entry(5)));
      await Future<void>.delayed(Duration.zero);
      expect(session.cardAt(5).preview?.entry.key, _entry(5).key);
    },
  );

  test('center-outward preparation is unique and capped for a large ring', () {
    session.dispose();
    session = RecentConversationSession.fromRecents(
      entries: List.generate(100, _entry),
      source: source,
      activity: activity,
    );
    expect(session.keysAround(0).map((key) => key.chat!.sessionId), [
      '0',
      '99',
      '1',
      '98',
      '2',
      '97',
      '3',
      '96',
      '4',
      '95',
    ]);
    session.prepare(session.keysAround(0));
    expect(source.reads.keys.map((key) => key.chat!.sessionId), [
      '0',
      '99',
      '1',
    ]);
    expect(
      () => session.prepare(List.generate(11, (i) => _entry(i).key)),
      throwsArgumentError,
    );
    expect(source.opens, isEmpty);
  });

  testWidgets(
    'timeout and pause retain physical read slots until I/O settles',
    (tester) async {
      session.prepare(session.keysAround(0));
      final first = source.reads.keys.toList();
      await tester.pump(const Duration(seconds: 6));
      expect(session.cardAt(0).error, isNotNull);
      expect(source.reads, hasLength(3));
      session.pausePreparation();
      for (final key in first) {
        source.reads[key]!.complete(
          _preview(_entry(int.parse(key.chat!.sessionId))),
        );
      }
      await tester.pump();
      expect(
        source.reads,
        hasLength(3),
        reason: 'No new reads start during motion.',
      );
      expect(session.cardAt(0).preview, isNull);
      session.prepare(session.keysAround(4, limit: 3));
      expect(source.reads, hasLength(6));
      expect(source.opens, isEmpty);
      session.dispose();
    },
  );

  test(
    'source revision invalidates cached facts and rejects an old read',
    () async {
      source.cached = true;
      session.prepare(session.keysAround(0, limit: 3));
      source.revisions[_entry(0).key] = 1;
      source.notifyListeners();
      expect(session.cardAt(0).preview, isNull);
      session.prepare(session.keysAround(0, limit: 3));
      expect(session.cardAt(0).preview, isNotNull);
      source.cached = false;
      session.prepare([_entry(3).key]);
      source.revisions[_entry(3).key] = 1;
      session.pausePreparation();
      source.reads[_entry(3).key]!.complete(_preview(_entry(3)));
      await Future<void>.delayed(Duration.zero);
      expect(session.cardAt(3).preview, isNull);
    },
  );

  test('an obsolete read failure cannot poison a newer revision', () async {
    final key = _entry(0).key;
    session.prepare([key]);
    final old = source.reads[key]!;
    source.revisions[key] = 1;
    source.cached = true;
    source.notifyListeners();
    session.prepare([key]);
    old.completeError(StateError('Old request failed'));
    await Future<void>.delayed(Duration.zero);
    expect(session.cardAt(0).error, isNull);
    expect(session.cardAt(0).preview, isNotNull);
  });

  test(
    'opening reads pending neighbors without moving membership and pauses',
    () async {
      source.selected = _entry(0).key;
      session.dispose();
      source.catalogRead = Completer<RecentConversationCatalog>();
      session = RecentConversationSession.fromChat(
        chat: _entry(0),
        source: source,
        activity: () => activity,
      );
      session.setMembershipPaused(true);
      session.activate();
      session.prepareOpeningNeighbors({});
      expect(session.entries, hasLength(1));
      expect(
        source.reads.keys,
        unorderedEquals([_entry(7).key, _entry(1).key]),
      );
      session.pausePreparation();
      source.reads[_entry(7).key]!.complete(_preview(_entry(7)));
      source.reads[_entry(1).key]!.complete(_preview(_entry(1)));
      await Future<void>.delayed(Duration.zero);
      source.currentEntries.add(_entry(8));
      source.notifyListeners();
      expect(
        source.reads,
        hasLength(2),
        reason: 'A pointer interruption must stop new opening admission',
      );
      expect(session.entries, hasLength(1));
      source.catalogRead!.complete(source.catalog);
      await Future<void>.delayed(Duration.zero);
    },
  );

  test('opening skips neighbors with ready pixel cache entries', () {
    enterChat();
    session.setMembershipPaused(true);
    session.activate();
    session.prepareOpeningNeighbors({_entry(7).key, _entry(1).key});
    expect(source.reads, isEmpty);
  });

  test('cached previews publish without I/O or a motion tick', () {
    source.cached = true;
    RecentConversationPreview? observed;
    session.addListener(() => observed = session.cardAt(0).preview);
    session.prepare(session.keysAround(0, limit: 3));
    expect(observed?.entry.key, _entry(0).key);
    expect(source.reads, isEmpty);
    expect(source.opens, isEmpty);
  });

  test('late preview cannot publish after disposal', () async {
    session.prepare(session.keysAround(0, limit: 3));
    var changes = 0;
    session.addListener(() => changes++);
    session.dispose();
    for (final entry in source.reads.entries) {
      entry.value.complete(
        _preview(_entry(int.parse(entry.key.chat!.sessionId))),
      );
    }
    await Future<void>.delayed(Duration.zero);
    expect(changes, 0);
  });

  test(
    'only committed selections open; lifetime fences held selection',
    () async {
      expect(await session.select(_entry(0).key), isTrue);
      source.heldOpen = Completer<void>();
      final selecting = session.select(_entry(1).key);
      session.dispose();
      source.heldOpen!.complete();
      expect(await selecting, isFalse);
      expect(source.selected, _entry(0).key);
    },
  );

  test('failed opening keeps the current chat available', () async {
    await session.select(_entry(0).key);
    source.failOpen = true;
    expect(await session.select(_entry(1).key), isFalse);
    expect(session.selected, _entry(0).key);
    expect(session.error, isNotNull);
    expect(session.active, isTrue);
  });

  test(
    'Coordination refusal keeps ownership uncertain and permits retry',
    () async {
      await session.select(_entry(0).key);
      source.openFailure = JsonRpcError(
        'session.resume',
        'runtime_coordination_required',
        code: 4001,
        reason: 'runtime_coordination_required',
      );
      expect(await session.select(_entry(1).key), isFalse);
      expect(session.selected, _entry(0).key);
      expect(session.selecting, isFalse);
      expect(
        session.error,
        'Sending is unavailable. Hermes could not confirm chat ownership. If this chat is open in another app, close it there, then retry.',
      );
      source.openFailure = null;
      expect(await session.select(_entry(1).key), isTrue);
      expect(session.error, isNull);
    },
  );

  test(
    'external selection retires the ring and prevents further opening',
    () async {
      await session.select(_entry(0).key);
      source.selected = _entry(3).key;
      source.notifyListeners();
      expect(session.active, isFalse);
      expect(await session.select(_entry(0).key), isFalse);
      expect(source.selected, _entry(3).key);
    },
  );

  test('disposal from observer safely fences further publications', () async {
    session.addListener(session.dispose);
    expect(await session.select(_entry(0).key), isFalse);
    expect(source.selected, isNull);
  });

  testWidgets(
    'focused preview determines cue direction and cue observer can retire visit',
    (tester) async {
      await session.select(_entry(0).key);
      session.setInteractive(true, origin: _entry(6).key);
      ConversationNudge? delivered;
      session.nudges.addListener(() {
        delivered = session.nudges.value;
        session.dispose();
      });
      activity.value = ChatNoticeActivity(
        key: _entry(5).key,
        kind: ConversationActivityKind.reply,
        identity: 'answer:5',
        sequence: 1,
      );
      await tester.pump(const Duration(milliseconds: 200));
      expect(session.active, isFalse);
      expect(delivered?.direction, ConversationDirection.left);
    },
  );

  testWidgets(
    'fresh group replies nudge their exact conversation without opening it',
    (tester) async {
      final group = RecentConversationEntry.group(
        BotGroup(
          scope: _scope,
          instance: 'Home',
          id: 'room',
          name: 'Discussion',
          members: const [],
          observationComplete: true,
        ),
        unread: true,
      );
      source.currentEntries.insert(1, group);
      source.notifyListeners();
      await session.select(_entry(0).key);
      source.opens.clear();
      session.setInteractive(true, origin: _entry(0).key);
      activity.value = ChatNoticeActivity(
        key: group.key,
        kind: ConversationActivityKind.reply,
        identity: 'answer:2',
        sequence: 1,
      );
      await tester.pump(const Duration(milliseconds: 200));
      expect(session.nudges.value?.key, group.key);
      expect(session.nudges.value?.direction, ConversationDirection.right);
      expect(source.opens, isEmpty);
      expect(source.reads, isEmpty);
      final delivered = session.nudges.value;
      session.setInteractive(true, origin: group.key);
      activity.value = ChatNoticeActivity(
        key: group.key,
        kind: ConversationActivityKind.reply,
        identity: 'answer:3',
        sequence: 2,
      );
      await tester.pump(const Duration(milliseconds: 200));
      expect(session.nudges.value, same(delivered));
    },
  );

  for (final (reason, index, interactive) in [
    ('quiet history', 1, false),
    ('current conversation', 0, true),
    ('nonmember conversation', 20, true),
  ]) {
    testWidgets('$reason does not emit an arrival cue', (tester) async {
      await session.select(_entry(0).key);
      if (interactive) session.setInteractive(true, origin: session.selected);
      activity.value = ChatNoticeActivity(
        key: _entry(index).key,
        kind: ConversationActivityKind.reply,
        identity: 'ignored',
        sequence: 1,
      );
      if (!interactive) session.setInteractive(true, origin: session.selected);
      await tester.pump(const Duration(milliseconds: 200));
      expect(session.nudges.value, isNull);
    });
  }

  testWidgets('coalesced arrival cues prioritize input needed over a reply', (
    tester,
  ) async {
    await session.select(_entry(0).key);
    session.setInteractive(true, origin: session.selected);
    activity.value = ChatNoticeActivity(
      key: _entry(7).key,
      kind: ConversationActivityKind.inputNeeded,
      identity: 'needs-input',
      sequence: 1,
    );
    activity.value = ChatNoticeActivity(
      key: _entry(1).key,
      kind: ConversationActivityKind.reply,
      identity: 'reply',
      sequence: 2,
    );
    await tester.pump(const Duration(milliseconds: 200));
    expect(session.nudges.value?.kind, ConversationActivityKind.inputNeeded);
    expect(session.nudges.value?.direction, ConversationDirection.left);
    expect(session.nudges.value?.key, _entry(7).key);
  });

  testWidgets('leaving interactive mode discards a queued arrival cue', (
    tester,
  ) async {
    await session.select(_entry(0).key);
    session.setInteractive(true, origin: session.selected);
    activity.value = ChatNoticeActivity(
      key: _entry(1).key,
      kind: ConversationActivityKind.reply,
      identity: 'queued',
      sequence: 1,
    );
    session.setInteractive(false, origin: null);
    await tester.pump(const Duration(milliseconds: 200));
    session.setInteractive(true, origin: session.selected);
    await tester.pump(const Duration(milliseconds: 200));
    expect(session.nudges.value, isNull);
  });
}
