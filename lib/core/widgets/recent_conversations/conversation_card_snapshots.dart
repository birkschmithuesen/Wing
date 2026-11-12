import 'dart:ui' as ui;

import '../../models/recent_conversation.dart';
import '../../services/recent_conversation_snapshots.dart';

/// Rendering adapter. Image retention, eviction and disposal belong to the
/// workspace catalog; this borrower only supplies and reads raster resources.
final class ConversationCardSnapshots {
  ConversationCardSnapshots(
    this._cache, {
    required this.environment,
    required this.liveEnvironment,
  });
  final RecentConversationSnapshots _cache;
  final Object Function() environment, liveEnvironment;

  int get byteLimit => _cache.byteLimit;
  Iterable<RecentConversationKey> get keys => {
    ..._cache.keysFor(environment()),
    ..._cache.keysFor(liveEnvironment()),
  };

  ui.Image? imageFor(RecentConversationKey key) {
    final resource =
        _cache.snapshotFor(key, environment: liveEnvironment()) ??
        _cache.snapshotFor(key, environment: environment());
    return (resource as _ImageSnapshot?)?.image;
  }

  bool isLive(RecentConversationKey key) =>
      _cache.isLive(key, environment: liveEnvironment());
  Object? revisionFor(RecentConversationKey key) =>
      _cache.revisionFor(key, environment: liveEnvironment()) ??
      _cache.revisionFor(key, environment: environment());

  void reserve(int bytes) => _cache.reserve(bytes);
  void release(int bytes) => _cache.release(bytes);
  void retain(Set<RecentConversationKey> keys) => _cache.retain(keys);

  void record(
    RecentConversationKey key,
    ui.Image image, {
    required bool live,
    required Object revision,
  }) => _cache.record(
    key,
    _ImageSnapshot(image),
    live: live,
    revision: revision,
    environment: live ? liveEnvironment() : environment(),
  );
}

final class _ImageSnapshot implements RecentConversationSnapshot {
  _ImageSnapshot(this.image);
  final ui.Image image;
  @override
  int get byteSize => image.width * image.height * 4;
  @override
  void dispose() => image.dispose();
}
