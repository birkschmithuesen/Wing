import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/services/bot_screen_session.dart';
import 'package:wing/core/models/operational_error.dart';
import 'support/bot_display_fixture.dart';

// Observe when the fixture actually reaches a held I/O stage. A sleep cannot
// establish whether takeover was dispatched or a connection reached its gate.
class _EnteredGate implements Completer<void> {
  _EnteredGate() {
    addTearDown(() {
      if (!_released.isCompleted) _released.complete();
    });
  }

  final entered = Completer<void>();
  final _released = Completer<void>();

  @override
  Future<void> get future {
    if (!entered.isCompleted) entered.complete();
    return _released.future;
  }

  @override
  bool get isCompleted => _released.isCompleted;

  @override
  void complete([FutureOr<void>? value]) => _released.complete(value);

  @override
  void completeError(Object error, [StackTrace? stackTrace]) =>
      _released.completeError(error, stackTrace);
}

Future<void> connected(BotScreenSession session) async {
  final ready = Completer<void>();
  void observe() {
    if (ready.isCompleted) return;
    if (session.connected && !session.busy) {
      ready.complete();
    } else if (session.error != null) {
      ready.completeError(StateError(session.error!));
    }
  }

  session.addListener(observe);
  try {
    observe();
    await ready.future;
  } finally {
    session.removeListener(observe);
  }
}

Future<BotScreenSession> open(
  DisplayFixture fixture, {
  OperationalErrorReporter? onOperationalError,
}) async {
  final bot = (await fixture.roster.repository.bots()).first;
  final session = BotScreenSession(
    fixture.repository,
    bot,
    onOperationalError: onOperationalError,
  )..setVisible(true);
  addTearDown(session.dispose);
  await connected(session);
  expect(session.connected, true);
  return session;
}

void main() {
  test(
    'desktop reports live failure and recovery but keeps lease command errors local',
    () async {
      final fixture = DisplayFixture();
      final observations = <OperationalErrorObservation>[];
      final screen = await open(fixture, onOperationalError: observations.add);
      expect(observations.single.error, isNull);
      await screen.takeOver();
      fixture.failRelease = true;
      await screen.handBack();
      expect(screen.error, isNotNull);
      expect(observations, hasLength(1));

      final held = fixture.statusWait = _EnteredGate();
      final read = screen.refresh();
      await held.entered.future;
      held.completeError(StateError('Offline'));
      await read;
      final issue = observations.last;
      expect(issue.error, isNotNull);
      fixture.statusWait = null;
      await screen.refresh();
      await connected(screen);
      expect(observations.last.operation, issue.operation);
      expect(observations.last.error, isNull);

      final departed = fixture.statusWait = _EnteredGate();
      final late = screen.refresh();
      await departed.entered.future;
      screen.setVisible(false);
      final count = observations.length;
      departed.completeError(StateError('Retired'));
      await late;
      expect(observations, hasLength(count));
      fixture.statusWait = null;
      fixture.failRelease = false;
      await screen.close();
    },
  );

  test(
    'watch is passive; only confirmed own lease admits keyboard and pointer',
    () async {
      final fixture = DisplayFixture();
      final screen = await open(fixture);
      final peer = fixture.peers.single;
      final count = peer.sent.length;
      screen.typeText('secret');
      screen.pointer(2, 1, 1);
      expect(peer.sent, hasLength(count));
      expect(fixture.calls.where((c) => c.$2.contains('lease.')), isEmpty);
      final acquisition = _EnteredGate();
      fixture.acquireWait = acquisition;
      final taking = screen.takeOver();
      await acquisition.entered.future;
      screen.typeText('blocked');
      expect(peer.sent, hasLength(count));
      fixture.acquireWait!.complete();
      await taking;
      expect(screen.canInput, true);
      screen.typeText('Aé😀');
      expect(peer.sent.where((p) => p.length == 8 && p[0] == 4), hasLength(6));
      expect(
        fixture.calls.where((c) => c.$2 == 'display.lease.acquire').single.$1,
        'atlas',
      );
      fixture.statusWait = Completer();
      final refresh = screen.refresh();
      expect(
        screen.canInput,
        true,
        reason: 'Routine status polling must not dismiss the keyboard',
      );
      fixture.statusWait!.complete();
      await refresh;
      await screen.handBack();
      expect(screen.canInput, false);
      expect(fixture.holder, 'agent');
      await screen.close();
      expect(fixture.releases, 1);
    },
  );

  test(
    'closing waits for dispatched takeover and releases only its viewer',
    () async {
      final f = DisplayFixture();
      final screen = await open(f);
      final acquisition = _EnteredGate();
      f.acquireWait = acquisition;
      final take = screen.takeOver();
      await acquisition.entered.future;
      final close = screen.close();
      expect(screen.canInput, false);
      f.acquireWait!.complete();
      await take;
      expect(await close, true);
      expect(f.holder, 'agent');
      final release = f.calls
          .where((c) => c.$2 == 'display.lease.release')
          .single;
      expect(release.$3, {'viewer_id': 'phone-viewer'});
      expect(f.releases, 1);
    },
  );

  test(
    'retirement before dispatch prevents takeover; late connection is closed',
    () async {
      final f = DisplayFixture();
      final s = await open(f);
      final admission = _EnteredGate();
      f.beforeAcquire = admission;
      final take = s.takeOver();
      await admission.entered.future;
      final close = s.close();
      f.beforeAcquire!.complete();
      await take;
      expect(await close, true);
      expect(f.calls.where((c) => c.$2.contains('lease.')), isEmpty);
      final connection = _EnteredGate();
      final late = DisplayFixture()..connectWait = connection;
      final bot = (await late.roster.repository.bots()).first;
      final pending = BotScreenSession(late.repository, bot)..setVisible(true);
      addTearDown(pending.dispose);
      await connection.entered.future;
      final exit = pending.close();
      late.connectWait!.complete();
      expect(await exit, true);
      expect(late.peers.single.closed, true);
    },
  );

  test(
    'background retains control and clears pixels; reconnect never auto-acquires',
    () async {
      final f = DisplayFixture();
      final s = await open(f);
      await s.takeOver();
      s.setVisible(false);
      expect(s.frame, isNull);
      expect(s.canInput, false);
      expect(f.holder, 'human');
      s.setVisible(true);
      await connected(s);
      expect(s.canInput, true);
      expect(
        f.calls.where((c) => c.$2 == 'display.lease.acquire'),
        hasLength(1),
      );
      f.viewer = 'new-rpc-viewer';
      s.setVisible(false);
      s.setVisible(true);
      await connected(s);
      expect(s.canInput, false);
      expect(s.humanHasControl, true);
      await s.handBack(force: true);
      expect(f.calls.last.$3, {'force': true});
      await s.close();
    },
  );

  test(
    'failed cleanup stays open; another confirmed holder is never force-released',
    () async {
      final f = DisplayFixture();
      final s = await open(f);
      await s.takeOver();
      f.failRelease = true;
      expect(await s.close(), false);
      expect(f.releases, 0);
      expect(f.holder, 'human');
      expect(s.error, isNotNull);
      f.failRelease = false;
      f.held = 'desktop-viewer';
      f.epoch++;
      expect(await s.close(), true);
      expect(f.held, 'desktop-viewer');
      expect(f.calls.where((c) => c.$3['force'] == true), isEmpty);
      expect(f.releases, 1);
    },
  );
  test(
    'modifier chords release every key and handback releases held pointer before lease transition',
    () async {
      final f = DisplayFixture();
      final session = await open(f);
      await session.takeOver();
      final peer = f.peers.single;
      final before = peer.sent.length;
      session.key(99, modifiers: {0xffe3, 0xffe9});
      final keys = peer.sent.skip(before).where((p) => p[0] == 4).toList();
      expect(
        keys
            .map(
              (p) => (p[1], (p[4] << 24) | (p[5] << 16) | (p[6] << 8) | p[7]),
            )
            .toList(),
        [(1, 0xffe3), (1, 0xffe9), (1, 99), (0, 99), (0, 0xffe9), (0, 0xffe3)],
      );
      session.pointer(2, 1, 1);
      await session.handBack();
      expect(peer.sent.where((p) => p[0] == 5).last[1], 0);
      final retired = peer.sent.length;
      session.key(99, modifiers: {0xffe3});
      expect(peer.sent.length, retired);
      await session.close();
    },
  );
  test(
    'temporary focus loss gates input without replacing the viewer or lease',
    () async {
      final f = DisplayFixture();
      final session = await open(f);
      await session.takeOver();
      final peer = f.peers.single, epoch = f.epoch;
      session.pointer(2, 1, 1);
      session.setFocused(false);
      expect(peer.closed, false);
      expect(session.canInput, false);
      expect(peer.sent.where((p) => p[0] == 5).last[1], 0);
      final count = peer.sent.length;
      session.typeText('blocked');
      session.pointer(1, 1, 1);
      expect(peer.sent.length, count);
      session.setVisible(true);
      session.setFocused(true);
      await session.refresh();
      expect(session.canInput, true);
      expect(f.peers, hasLength(1));
      expect(f.epoch, epoch);
      expect(f.calls.where((c) => c.$2 == 'display.observe'), hasLength(1));
      await session.close();
    },
  );
  test(
    'phone clipboard reads only under ownership and rechecks after await',
    () async {
      final f = DisplayFixture();
      final session = await open(f);
      var reads = 0;
      await session.pasteClipboard(() async {
        reads++;
        return 'secret';
      });
      expect(reads, 0);
      await session.takeOver();
      final read = Completer<String?>();
      final paste = session.pasteClipboard(() => read.future);
      expect(session.pasting, true);
      await session.handBack();
      final count = f.peers.single.sent.length;
      final rejected = expectLater(paste, throwsStateError);
      read.complete('secret');
      await rejected;
      expect(f.peers.single.sent.length, count);
      expect(session.pasting, false);
      await session.close();
    },
  );

  test(
    'paste announces clipboard then Ctrl-V and serves the request without Enter',
    () async {
      final f = DisplayFixture();
      final session = await open(f);
      await session.takeOver();
      final count = f.peers.single.sent.length;
      await session.pasteClipboard(() async => 'first\nsecond');
      final packets = f.peers.single.sent.skip(count).toList();
      expect(packets.map((p) => p[0]), [6, 6, 4, 4, 4, 4, 6]);
      expect(
        packets.where((p) => p[0] == 4).map((p) => (p[1], p[6] * 256 + p[7])),
        [(1, 0xffe3), (1, 0x76), (0, 0x76), (0, 0xffe3)],
      );
      await session.close();
    },
  );
  test(
    'paste rechecks lease after the remote application requests clipboard',
    () async {
      final f = DisplayFixture();
      final session = await open(f);
      await session.takeOver();
      f.peers.single.requestClipboardOnPaste = false;
      final paste = session.pasteClipboard(() async => 'private text');
      final rejected = expectLater(paste, throwsStateError);
      await Future<void>.delayed(Duration.zero);
      expect(session.pasting, isTrue);
      await session.handBack();
      final count = f.peers.single.sent.length;
      f.peers.single.requestClipboard();
      await rejected;
      expect(f.peers.single.sent.length, count);
      expect(session.pasting, isFalse);
      await session.close();
    },
  );
}
