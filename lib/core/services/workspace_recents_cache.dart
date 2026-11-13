import 'package:flutter/foundation.dart';

import '../models/recent_conversation.dart';
import 'bots_session.dart';
import 'recent_conversation_snapshots.dart';

/// The shared workspace observation and retention borrowed by conversation
/// sources. The owner controls publication, refreshes and resource disposal.
abstract interface class WorkspaceRecentsCache implements Listenable {
  Object get workspaceOwner;
  bool get current;
  BotsSession get bots;
  RecentConversationCatalog get catalog;
  RecentConversationSnapshots get snapshots;
  Future<void> refresh({bool force = false});
  void setVisible(Object reader, bool visible);
  Object readingRevision(List<Map<String, dynamic>> messages);
}
