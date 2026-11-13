part of 'bots_session.dart';

/// Only this helper retains encoded bot images. Metadata, completed reads and
/// pixel tokens never own a buffer. Each BotsSession has its own budget.
final class _BotAvatarCache {
  final entries = <WorkspaceScope, _BotAvatarEntry>{};
  final borrowers = <_BotAvatarBorrower>{};
  Set<WorkspaceScope> warm = {};
  WorkspaceScope? selected;
  static const countLimit = 10;
  static const byteLimit = 20 * 1024 * 1024;

  bool demanded(WorkspaceScope scope) =>
      borrowers.any((borrower) => borrower._demand.contains(scope));
  bool admitted(WorkspaceScope scope) =>
      warm.contains(scope) || demanded(scope);
  bool imageMode(BotRecord bot) => !bot.hasExplicitClassicShape;

  void observe(BotRecord bot) {
    final entry = entries.putIfAbsent(bot.scope, _BotAvatarEntry.new);
    final previous = entry.bot;
    entry.bot = bot;
    if (previous == null) return;
    if (previous.hasAvatar != bot.hasAvatar) {
      if (bot.hasAvatar || entry.signature != null) {
        entry.generation++;
        entry.due = true;
        entry.negative = false;
      }
    }
    if (imageMode(previous) != imageMode(bot)) {
      entry.generation++;
      entry.due = true;
      if (!imageMode(bot)) entry.bytes = null;
    }
  }

  void selectWarm() {
    final candidates =
        entries.entries.where((item) {
          final bot = item.value.bot!;
          return imageMode(bot) &&
              (bot.hasAvatar || item.value.signature != null);
        }).toList()..sort((a, b) {
          if (a.key == selected && b.key != selected) return -1;
          if (b.key == selected && a.key != selected) return 1;
          final left = a.value.bot!.canonicalLastActive;
          final right = b.value.bot!.canonicalLastActive;
          final activity = switch ((left, right)) {
            (final DateTime l, final DateTime r) => r.compareTo(l),
            (null, final DateTime _) => 1,
            (final DateTime _, null) => -1,
            _ => 0,
          };
          if (activity != 0) return activity;
          final connection = a.key.connectionIdentity.compareTo(
            b.key.connectionIdentity,
          );
          if (connection != 0) return connection;
          final id = a.key.connectionId.compareTo(b.key.connectionId);
          return id != 0 ? id : a.key.profileName.compareTo(b.key.profileName);
        });
    final next = <WorkspaceScope>{};
    var bytes = 0;
    for (final candidate in candidates) {
      if (next.length == countLimit) break;
      final size = candidate.value.knownSize;
      if (bytes + size > byteLimit) continue;
      next.add(candidate.key);
      bytes += size;
    }
    warm = next;
    releaseUnused();
  }

  void releaseUnused() {
    for (final item in entries.entries) {
      if (!admitted(item.key)) item.value.bytes = null;
    }
  }

  bool shouldRead(WorkspaceScope scope, DateTime now) {
    final entry = entries[scope];
    if (entry == null || !admitted(scope) || !imageMode(entry.bot!)) {
      return false;
    }
    if (!entry.bot!.hasAvatar && entry.signature == null && !entry.due) {
      return false;
    }
    if (entry.failedAt != null &&
        now.difference(entry.failedAt!) < const Duration(seconds: 30)) {
      return false;
    }
    final fresh =
        entry.validatedAt != null &&
        now.difference(entry.validatedAt!) < const Duration(minutes: 5);
    if (entry.negative && fresh && !entry.due) return false;
    return entry.due || entry.bytes == null || !fresh;
  }

  bool accept(WorkspaceScope scope, BotAvatarRead outcome, DateTime now) {
    final entry = entries[scope]!;
    if (outcome.kind == BotAvatarReadKind.unavailable) {
      entry.failedAt = now;
      return false;
    }
    entry.failedAt = null;
    entry.validatedAt = now;
    entry.due = false;
    entry.negative = outcome.kind == BotAvatarReadKind.missing;
    final bytes = outcome.bytes;
    final signature = bytes == null ? null : sha256.convert(bytes).toString();
    final changed = entry.signature != signature;
    if (changed) entry.version++;
    if (bytes == null || !listEquals(bytes, entry.bytes)) entry.bytes = bytes;
    entry.signature = signature;
    entry.knownSize = bytes?.lengthInBytes ?? 0;
    selectWarm();
    return changed;
  }

  void due(WorkspaceScope scope) {
    final entry = entries[scope];
    if (entry == null) return;
    entry.generation++;
    entry.due = true;
    entry.negative = false;
    entry.failedAt = null;
  }

  void forget(WorkspaceScope scope) {
    entries.remove(scope)?.generation++;
    warm.remove(scope);
  }
}

final class _BotAvatarEntry {
  BotRecord? bot;
  Uint8List? bytes;
  String? signature;
  int knownSize = 0, version = 0, generation = 0;
  bool negative = false, due = false;
  DateTime? validatedAt, failedAt;
}

abstract interface class BotAvatarBorrower {
  void replaceDemand(Set<WorkspaceScope> profiles);
  Uint8List? imageFor(WorkspaceScope profile);
  Listenable get changes;
  void dispose();
}

final class _BotAvatarBorrower extends ChangeNotifier
    implements BotAvatarBorrower {
  _BotAvatarBorrower(this.owner);
  final BotsSession owner;
  Set<WorkspaceScope> _demand = {};
  bool _closed = false;
  @override
  Listenable get changes => this;
  @override
  void replaceDemand(Set<WorkspaceScope> profiles) {
    if (_closed || setEquals(_demand, profiles)) return;
    _demand = Set.of(profiles);
    owner._avatars.releaseUnused();
    owner._wakeAvatars();
  }

  @override
  Uint8List? imageFor(WorkspaceScope profile) =>
      !_closed && _demand.contains(profile)
      ? owner._avatars.entries[profile]?.bytes
      : null;
  void changed() {
    if (!_closed) notifyListeners();
  }

  @override
  void dispose() {
    if (_closed) return;
    _closed = true;
    _demand = {};
    owner._avatars.borrowers.remove(this);
    owner._avatars.releaseUnused();
    super.dispose();
  }
}

/// A successful validation clock is independent of failure backoff and pending
/// publication. The owner supplies scope/mutation fences for each operation.
final class _BotsReadJob {
  DateTime? success, failed;
  void Function(bool)? onOutcome;
  Future<void>? pending;
  bool due(DateTime now, Duration age) =>
      (failed == null ||
          now.difference(failed!) >= const Duration(seconds: 30)) &&
      (success == null || now.difference(success!) >= age);
  Future<void> run(
    DateTime Function() now,
    Duration age,
    Future<bool> Function() read,
  ) {
    if (pending != null) return pending!;
    final started = now();
    if (!due(started, age)) return Future.value();
    final completion = Completer<void>();
    pending = completion.future;
    unawaited(() async {
      try {
        final validated = await read();
        if (validated) {
          // Network latency must not push a periodic wake past its next slot.
          success = started;
          failed = null;
        } else {
          failed = now();
        }
        onOutcome?.call(validated);
      } catch (_) {
        failed = now();
        onOutcome?.call(false);
      } finally {
        pending = null;
        completion.complete();
      }
    }());
    return completion.future;
  }
}
