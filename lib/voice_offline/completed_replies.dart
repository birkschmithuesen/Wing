import 'dart:async';

/// Successful turn completions with their final reply text, for hands-free
/// read-aloud. Emitted once per settled turn; failures and stops are skipped.
///
/// The chat is an opaque [Object] so this file does not import the controller
/// (which owns it); the voice driver casts it back to its ProfileChat.
class CompletedReplies {
  final _controller = StreamController<({Object chat, String text})>.broadcast();

  Stream<({Object chat, String text})> get stream => _controller.stream;

  void offer(Object chat, String text) {
    _controller.add((chat: chat, text: text));
  }

  Future<void> close() => _controller.close();
}
