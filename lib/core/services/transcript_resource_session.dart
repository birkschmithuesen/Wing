import 'dart:typed_data';

import '../models/skill_reader.dart';
import 'chat_outputs_session.dart';
import 'owned_remote_files.dart';
import 'profile_gateway.dart';
import 'skill_reader_session.dart';

/// One trace visit's captured files, output history and profile skill reader.
/// Main and child traces share the same preview and delivery policy owners.
final class TranscriptResourceSession {
  TranscriptResourceSession({
    required this.files,
    required this._loadHistory,
    required this._createSkillReader,
  });

  final OwnedRemoteFiles files;
  final Future<ProfileHistoryPage> Function(int) _loadHistory;
  final SkillReaderSession Function(SkillReaderTarget) _createSkillReader;
  bool _closed = false;

  void _requireActive() {
    if (_closed) throw StateError('This trace resource visit is closed.');
  }

  Future<Uint8List> loadImage(String path) async =>
      (await files.download(path)).bytes;

  Future<ProfileHistoryPage> _history(int offset) async {
    _requireActive();
    final page = await _loadHistory(offset);
    _requireActive();
    return page;
  }

  ChatOutputsSession createOutputsSession() {
    _requireActive();
    return ChatOutputsSession(
      loadHistory: _history,
      download: files.download,
      readText: files.readText,
    );
  }

  SkillReaderSession skillReader(SkillReaderTarget target) {
    _requireActive();
    return _createSkillReader(target);
  }

  void dispose() {
    if (_closed) return;
    _closed = true;
    files.dispose();
  }
}
