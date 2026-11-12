import 'dart:convert';

/// Decode delivered JSON for presentation, preserving raw output at its source.
Object? decodeToolPayload(String? raw) {
  if (raw == null) return null;
  var text = raw.trim();
  // Stock Hermes wraps external output with a security preamble. Preserve the
  // exact wrapper in raw details; extract only its enclosed data for display.
  if (text.startsWith('<untrusted_tool_result ') &&
      text.endsWith('</untrusted_tool_result>')) {
    final start = RegExp(r'^\s*[{\[]', multiLine: true).firstMatch(text);
    if (start != null) {
      text = text
          .substring(start.start, text.lastIndexOf('</untrusted_tool_result>'))
          .trim();
    }
  }
  try {
    return jsonDecode(text);
  } on FormatException {
    return _decodeBeforeHermesAdvisories(text) ?? raw;
  }
}

// Temporary, user-approved workaround for stock Hermes appending plain-text
// runtime advisories to JSON receipts:
// https://github.com/NousResearch/hermes-agent/issues/136238
// https://github.com/NousResearch/hermes-agent/pull/136241
// Check their status regularly during tool-parser maintenance. Once the upstream
// fix is implemented, verify stock Hermes preserves JSON and remove this helper,
// its matcher and the trailer-specific regression cases. Keep raw-preservation
// coverage. Never replace a recorded receipt with a fresh skills API read.
final _hermesAdvisoryTrailer = RegExp(
  r'\r?\n\r?\n\[(?:'
  r'Tool loop (?:warning|hard stop): [a-z_]+; count=\d+; [^\r\n]+'
  r'|hermes note: (?:this is the \d+(?:st|nd|rd|th) consecutive identical call to '
  r'|the last \d+ rounds repeated the same cycle of \d+ tool calls )[^\r\n]+'
  r')\]$',
);

Map? _decodeBeforeHermesAdvisories(String text) {
  var body = text;
  while (true) {
    final trailer = _hermesAdvisoryTrailer.firstMatch(body);
    if (trailer == null) break;
    body = body.substring(0, trailer.start).trimRight();
  }
  if (body == text) return null;
  // Only a complete JSON object qualifies; damaged JSON or unrelated trailing
  // text remains raw. The source receipt still includes every advisory byte.
  try {
    final decoded = jsonDecode(body);
    return decoded is Map ? decoded : null;
  } on FormatException {
    return null;
  }
}
