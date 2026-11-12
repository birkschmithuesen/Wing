enum ComposerAction {
  send('Send'),
  steer('Steer'),
  stop('Stop'),
  queue('Queue');

  const ComposerAction(this.label);
  final String label;

  static const runningDefaults = [steer, queue, stop];
}
