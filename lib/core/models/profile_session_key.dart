import 'hermes_profile.dart';

class ProfileSessionKey {
  final WorkspaceScope workspace;
  final String sessionId;
  const ProfileSessionKey(this.workspace, this.sessionId);
  Map<String, String> toJson() => {
    'connection': workspace.connectionId,
    'connection_identity': workspace.connectionIdentity,
    'profile': workspace.profileName,
    'session': sessionId,
  };
  factory ProfileSessionKey.fromJson(Map<String, dynamic> value) {
    final id = value['session'];
    final identity = value['connection_identity'];
    if (id is! String ||
        id.isEmpty ||
        identity is! String ||
        identity.isEmpty) {
      throw const FormatException('Missing session or connection ownership');
    }
    return ProfileSessionKey(
      WorkspaceScope(
        connectionId: value['connection'] as String,
        connectionIdentity: identity,
        profileName: value['profile'] as String,
      ),
      id,
    );
  }
  @override
  bool operator ==(Object other) =>
      other is ProfileSessionKey &&
      workspace == other.workspace &&
      sessionId == other.sessionId;
  @override
  int get hashCode => Object.hash(workspace, sessionId);
}
