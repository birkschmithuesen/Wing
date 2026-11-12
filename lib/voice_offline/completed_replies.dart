import 'dart:async';

import '../core/services/profile_workspace_controller.dart';

/// Successful turn completions with their final reply text, for hands-free
/// read-aloud. Emitted once per settled turn; failures and stops are skipped.
class CompletedReplies {
  final _controller =
      StreamController<({ProfileChat chat, String text})>.broadcast();

  Stream<({ProfileChat chat, String text})> get stream => _controller.stream;

  void offer(ProfileChat chat, String text) {
    _controller.add((chat: chat, text: text));
  }

  Future<void> close() => _controller.close();
}
