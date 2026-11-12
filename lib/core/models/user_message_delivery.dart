/// Stock bot delivery envelopes and the gateway's process-batch container.
/// These arrive with the user role, but are not messages authored by a human.
class UserMessageDelivery {
  const UserMessageDelivery(
    this.kind,
    this.headline,
    this.detail, {
    this.sender,
    this.senderHandle,
    this.botDelivery = false,
    this.processes = const [],
  });

  final String kind;
  final String headline;
  final String detail;
  final String? sender;
  final String? senderHandle;
  final bool botDelivery;
  final List<ProcessCompletion> processes;
}

/// Exact evidence from the stock process-completion producer, not a receipt
/// that delivery succeeded. The runner output determines the exchange outcome.
final class ProcessCompletion {
  const ProcessCompletion({
    required this.id,
    required this.command,
    required this.output,
    required this.raw,
    required this.exitCode,
    required this.botDelivery,
  });
  final String id, command, output, raw;
  final int? exitCode;
  final bool botDelivery;
}

UserMessageDelivery? userMessageDelivery(String text) {
  text = text.trim();
  final process = processCompletionDelivery(text);
  if (process != null) return process;
  final agent = _agentMessage.firstMatch(text);
  if (agent == null) return null;
  final sender = agent.group(1)!.trim();
  return UserMessageDelivery(
    'agent_message',
    'Message from $sender',
    agent.group(3)!.trim(),
    sender: sender,
    senderHandle: agent.group(2),
  );
}

/// Extract the result from Hermes's producer-defined completion envelope.
/// Typed process_complete notices use this only for their disclosed body. Stock
/// direct-event dispatch also emits these envelopes without a display kind.
UserMessageDelivery? processCompletionDelivery(String text) =>
    _processDelivery(text.trim()) ?? _processBatchDelivery(text.trim());

UserMessageDelivery? _processDelivery(String text) {
  if (_processNotification.hasMatch(text)) {
    final body = text
        .replaceFirst(RegExp(r'^\[IMPORTANT:\s*'), '')
        .replaceFirst(RegExp(r'\]$'), '');
    final newline = body.indexOf('\n');
    final headline = (newline == -1 ? body : body.substring(0, newline)).trim();
    final detail = newline == -1 ? '' : body.substring(newline + 1).trim();
    final outputStart = detail.indexOf('\nOutput:');
    final command = outputStart == -1 ? '' : detail.substring(0, outputStart);
    final botDelivery =
        command.startsWith('Command: ') &&
        _botDeliveryCommand.hasMatch(command);
    final exit = RegExp(
      r'\(exit code (-?\d+)(?:, SIGTERM)?\)\.$',
    ).firstMatch(headline);
    final identity = RegExp(r'^Background process (\S+) ').firstMatch(headline);
    final deliveryTitle = botDelivery && exit != null
        ? exit.group(1) == '0'
              ? 'Bot delivery process finished'
              : 'Bot delivery process failed'
        : headline;
    return UserMessageDelivery(
      'process_notification',
      deliveryTitle,
      detail,
      botDelivery: botDelivery,
      processes: identity == null || outputStart == -1
          ? const []
          : List.unmodifiable([
              ProcessCompletion(
                id: identity.group(1)!,
                command: command.startsWith('Command: ')
                    ? command.substring(9)
                    : command,
                output: body
                    .substring(body.indexOf('\nOutput:') + '\nOutput:'.length)
                    .replaceFirst(RegExp(r'^\r?\n'), ''),
                raw: text,
                exitCode: exit == null ? null : int.tryParse(exit.group(1)!),
                botDelivery: botDelivery,
              ),
            ]),
    );
  }
  return null;
}

/// ProcessNotificationBatch.render joins a count header and complete notices
/// with blank lines. Validate that container; do not match its agent instructions.
/// See docs/DESKTOP_PROCESS_BATCH_AUDIT_2026-09-14.md for the producer contract.
UserMessageDelivery? _processBatchDelivery(String text) {
  const prefix = '[IMPORTANT: ';
  const countSuffix = ' background processes completed.';
  const processPrefix = '[IMPORTANT: Background process ';
  if (!text.startsWith(prefix)) return null;
  final headerEnd = RegExp(r'\r?\n\r?\n').firstMatch(text);
  if (headerEnd == null) return null;
  final header = text.substring(0, headerEnd.start);
  final countEnd = header.indexOf(countSuffix, prefix.length);
  if (countEnd == -1 || header.contains('\n') || !header.endsWith(']')) {
    return null;
  }
  final countText = header.substring(prefix.length, countEnd);
  final count = int.tryParse(countText);
  if (count == null || count < 2 || '$count' != countText) return null;
  final body = text.substring(headerEnd.end);
  if (!body.startsWith(processPrefix)) return null;
  final parts = body.split(
    RegExp(r'\]\r?\n\r?\n\[IMPORTANT: Background process '),
  );
  if (parts.length != count) return null;
  final results = <String>[];
  final processes = <ProcessCompletion>[];
  for (var i = 0; i < parts.length; i++) {
    final envelope =
        '${i == 0 ? '' : processPrefix}${parts[i]}'
        '${i == parts.length - 1 ? '' : ']'}';
    final process = _processDelivery(envelope);
    if (process == null) return null;
    processes.addAll(process.processes);
    results.add(
      [process.headline, process.detail].where((s) => s.isNotEmpty).join('\n'),
    );
  }
  return UserMessageDelivery(
    'process_notification',
    '$count background processes completed',
    results.join('\n\n'),
    processes: List.unmodifiable(processes),
  );
}

final _processNotification = RegExp(
  r'^\[IMPORTANT: Background process [\s\S]*\]$',
);
final _botDeliveryCommand = RegExp(
  r'^Command: (?:\S*/)?python(?:\d+(?:\.\d+)*)?\s+(?:\S*/)?bot_mode_dm\.py\s+--(?:run-delivery|wait-reply)(?:\s|$)',
);
final _agentMessage = RegExp(
  r'^Message from (?:🤖\s*)?([^:\n(]{1,64}?)(?:\s*\(@([a-z0-9][a-z0-9_-]{0,63})\))?:\s*([\s\S]*)$',
  unicode: true,
);
