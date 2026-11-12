import 'hermes_profile.dart';

/// A server-confirmed change, published before any follow-up reads.
sealed class BrowserMutation {
  const BrowserMutation(this.owner);
  final WorkspaceScope owner;
}

class SessionBrowserMutation extends BrowserMutation {
  SessionBrowserMutation(
    super.owner,
    this.id, {
    Map<String, dynamic> changes = const {},
    this.projectId,
    this.deleted = false,
  }) : changes = Map.unmodifiable(changes);

  final String id;
  final Map<String, dynamic> changes;
  final String? projectId;
  final bool deleted;
}

class ProjectBrowserMutation extends BrowserMutation {
  ProjectBrowserMutation(super.owner, this.id, Map<String, dynamic>? project)
    : project = project == null ? null : Map.unmodifiable(project);

  final String id;

  /// Null means the project was deleted; its chats still exist.
  final Map<String, dynamic>? project;
}
