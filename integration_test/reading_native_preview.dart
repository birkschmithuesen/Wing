/// Disposable Android entry point for exercising real PDF/media/WebView plugins.
/// Fixtures are generated locally; this target never connects to Hermes.
library;

import 'package:wing/core/services/chat_outputs_session.dart';

import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:wing/core/models/app_preferences.dart';
import 'package:wing/core/models/gateway_activity.dart';
import 'package:wing/core/models/gateway_todo.dart';
import 'package:wing/core/screens/chat_outputs_screen.dart';
import 'package:wing/core/screens/pdf_preview_screen.dart';
import 'package:wing/core/services/media_preview_service.dart';
import 'package:wing/core/services/profile_gateway.dart';
import 'package:wing/core/services/remote_files_client.dart';
import 'package:wing/core/services/web_preview.dart';
import 'package:wing/core/widgets/markdown_message_content.dart';
import 'package:wing/core/widgets/profile_execution_activity.dart';
import 'package:wing/core/widgets/web_output_preview.dart';
import 'package:wing/core/theme/wing_theme.dart';
import 'package:wing/core/theme/profile_workspace_theme.dart';

void main() {
  if (!kDebugMode) throw StateError('Native reading QA requires debug mode.');
  runApp(const _StudioPreviewApp());
}

class _StudioPreviewApp extends StatefulWidget {
  const _StudioPreviewApp();

  @override
  State<_StudioPreviewApp> createState() => _StudioPreviewAppState();
}

class _StudioPreviewAppState extends State<_StudioPreviewApp> {
  Brightness _brightness = Brightness.dark;
  WorkspaceAccent _accent = WorkspaceAccent.teal;

  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: profileWorkspaceTheme(wingTheme(_brightness), accent: _accent),
    home: _Menu(
      toggleTheme: () => setState(
        () => _brightness = _brightness == Brightness.dark
            ? Brightness.light
            : Brightness.dark,
      ),
      nextAccent: () => setState(
        () => _accent = WorkspaceAccent
            .values[(_accent.index + 1) % WorkspaceAccent.values.length],
      ),
    ),
  );
}

class _Menu extends StatelessWidget {
  const _Menu({required this.toggleTheme, required this.nextAccent});
  final VoidCallback toggleTheme, nextAccent;

  @override
  Widget build(BuildContext context) {
    void open(Widget screen) => Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => screen));
    Future<void> play(String filename, List<int> bytes) async {
      try {
        final theme = Theme.of(context);
        final opened = await const MediaPreviewService().open(
          RemoteFileDownload(filename: filename, bytes: bytes),
          title: filename,
          appearance: {
            'dark': theme.brightness == Brightness.dark ? 1 : 0,
            'surface': theme.colorScheme.surface.toARGB32(),
            'text': theme.colorScheme.onSurface.toARGB32(),
            'accent': theme.colorScheme.primary.toARGB32(),
            'onAccent': theme.colorScheme.onPrimary.toARGB32(),
            'error': theme.colorScheme.error.toARGB32(),
          },
        );
        if (!opened) throw StateError('Native player unavailable');
      } catch (error) {
        if (context.mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text('$error')));
        }
      }
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Native reading QA'),
        actions: [
          IconButton(
            onPressed: toggleTheme,
            icon: const Icon(Icons.brightness_6),
            tooltip: 'Toggle theme',
          ),
          IconButton(
            onPressed: nextAccent,
            icon: const Icon(Icons.palette_outlined),
            tooltip: 'Next accent',
          ),
        ],
      ),
      body: ListView(
        children: [
          ListTile(
            title: const Text('Two-page PDF'),
            onTap: () => open(
              PdfPreviewScreen(
                title: 'QA two-page.pdf',
                download: () async =>
                    RemoteFileDownload(filename: 'qa.pdf', bytes: _pdf()),
              ),
            ),
          ),
          ListTile(
            title: const Text('Audio playback'),
            onTap: () => play('QA tone.wav', _wav()),
          ),
          ListTile(
            title: const Text('Video playback'),
            onTap: () => play(
              'QA test pattern.mp4',
              base64Decode(
                const String.fromEnvironment('HERMES_QA_VIDEO_BASE64'),
              ),
            ),
          ),
          ListTile(
            title: const Text('HTML preview'),
            onTap: () => open(
              const WebOutputPreview(
                title: 'QA HTML',
                format: WebOutputFormat.html,
                source:
                    '<!doctype html><html><meta name="viewport" content="width=device-width"><body style="background:#fff;color:#152231;padding:24px"><h1>Hermes reading check</h1><p>Local HTML preview.</p><img src="$_qaEmbeddedDataImage" alt="Embedded data image"><p>The green Data image must appear above.</p><button onclick="this.textContent=\'Interaction passed\'">Test interaction</button></body></html>',
              ),
            ),
          ),
          ListTile(
            title: const Text('Diagram preview'),
            onTap: () => open(
              const WebOutputPreview(
                title: 'QA diagram',
                format: WebOutputFormat.mermaid,
                source:
                    'flowchart TD\n  A[Draft] --> B[Hermes server]\n  B --> C[Read result]',
              ),
            ),
          ),
          ListTile(
            title: const Text('Content and execution details'),
            onTap: () => open(_contentExecutionScreen()),
          ),
          ListTile(
            title: const Text('Diagram error'),
            onTap: () => open(
              const WebOutputPreview(
                title: 'Diagram error',
                format: WebOutputFormat.mermaid,
                source: 'This is intentionally invalid diagram syntax',
              ),
            ),
          ),
          ListTile(
            title: const Text('Media error'),
            onTap: () =>
                play('Invalid audio.wav', utf8.encode('Invalid audio')),
          ),
          ListTile(
            title: const Text('Browser preview'),
            onTap: () => openWebLink(
              Uri.parse(
                const String.fromEnvironment(
                  'HERMES_QA_BROWSER_URL',
                  defaultValue: 'http://127.0.0.1:8765/',
                ),
              ),
              WebLinkDestination.wing,
            ),
          ),
          ListTile(
            title: const Text('Markdown linked output'),
            onTap: () => open(_localOutputsScreen()),
          ),
        ],
      ),
    );
  }
}

const _qaEmbeddedDataImage =
    'data:image/svg+xml,%3Csvg%20xmlns%3D%22http%3A%2F%2Fwww.w3.org%2F2000%2Fsvg%22%20width%3D%22160%22%20height%3D%2260%22%3E%3Crect%20width%3D%22160%22%20height%3D%2260%22%20fill%3D%22%23005f49%22%2F%3E%3Ctext%20x%3D%2280%22%20y%3D%2238%22%20text-anchor%3D%22middle%22%20font-size%3D%2220%22%20fill%3D%22white%22%3EData%20image%3C%2Ftext%3E%3C%2Fsvg%3E';

const _qaReadingMarkdown = r'''
## Narrow reading fixture

| Stage | Owner | State | Long detail |
| --- | --- | --- | --- |
| Parse | Android | Complete | This wide table must scroll without clipping the final column. |
| Render | Hermes | Running | The reader must retain access to every column on a narrow screen. |

```dart
final longNativeQaValue = 'This line exercises horizontal scrolling and the wrap control on a narrow Android screen.';
```

```svg
<svg xmlns="http://www.w3.org/2000/svg" width="320" height="120" viewBox="0 0 320 120">
  <rect width="320" height="120" rx="16" fill="#25344a"/>
  <circle cx="62" cy="60" r="28" fill="#62d9a7"/>
  <path d="M98 60h116" stroke="#ffffff" stroke-width="8"/>
  <text x="224" y="68" fill="#ffffff" font-size="24">SVG QA</text>
</svg>
```
''';

Widget _contentExecutionScreen() {
  final tool = GatewayToolActivity.fromGatewayEvent('tool.complete', const {
    'tool_id': 'native-reading-tool',
    'name': 'inspect_native_fixture',
    'args': {'target': 'narrow Android screen'},
    'result': {'rows': 2, 'status': 'verified'},
    'duration_s': 0.4,
  })!;
  return Scaffold(
    appBar: AppBar(title: const Text('Content and execution QA')),
    body: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const MarkdownMessageContent(data: _qaReadingMarkdown),
        const Divider(height: 32),
        ProfileLiveToolActivity(activities: [tool]),
        const ProfileTodoPanel(
          todos: [
            GatewayTodo(
              id: 'native-reading-one',
              content: 'Inspect the wide table and code controls',
              status: GatewayTodoStatus.completed,
            ),
            GatewayTodo(
              id: 'native-reading-two',
              content: 'Open and return from the SVG preview',
              status: GatewayTodoStatus.inProgress,
              parent: 'native-reading-one',
            ),
          ],
        ),
        const ProfileReasoningDisclosure(
          text: 'The fixture uses public production widgets and local data.',
        ),
      ],
    ),
  );
}

const _qaMarkdownPath = '/qa/hermes-native-link-source-20260913.md';
const _qaTextPath = '/qa/hermes-native-linked-report-20260913.txt';
const _qaMarkdown =
    '''
# Local output link

[Open the linked text output]($_qaTextPath)
''';
const _qaText = 'Hermes native linked output bytes.\n';

Widget _localOutputsScreen() => ChatOutputsScreen(
  chatTitle: 'Local native QA',
  createSession: () => ChatOutputsSession(
    loadHistory: (offset) async => ProfileHistoryPage(
      'local-native-qa',
      const [
        {'id': 1, 'role': 'assistant', 'content': 'Saved $_qaMarkdownPath'},
      ],
      offset,
      500,
      isComplete: true,
    ),
    readText: (path) async {
      final text = switch (path) {
        _qaMarkdownPath => _qaMarkdown,
        _qaTextPath => _qaText,
        _ => throw StateError('Unknown local QA path'),
      };
      return RemoteTextPreview(
        path: path,
        text: text,
        language: path == _qaMarkdownPath ? 'markdown' : 'text',
        mimeType: path == _qaMarkdownPath
            ? 'text/markdown; charset=utf-8'
            : 'text/plain; charset=utf-8',
        binary: false,
        truncated: false,
      );
    },
    download: (path) async {
      final text = switch (path) {
        _qaMarkdownPath => _qaMarkdown,
        _qaTextPath => _qaText,
        _ => throw StateError('Unknown local QA path'),
      };
      return RemoteFileDownload(
        filename: path == _qaMarkdownPath
            ? 'hermes-native-link-source-20260913.md'
            : 'hermes-native-linked-report-20260913.txt',
        bytes: utf8.encode(text),
      );
    },
  ),
);

Uint8List _pdf() {
  final objects = <String>[
    '<< /Type /Catalog /Pages 2 0 R >>',
    '<< /Type /Pages /Kids [3 0 R 4 0 R] /Count 2 >>',
    for (final stream in [6, 7])
      '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 400] /Resources << /Font << /F1 5 0 R >> >> /Contents $stream 0 R >>',
    '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>',
    for (final page in [1, 2])
      _pdfStream('BT /F1 20 Tf 30 330 Td (Hermes PDF page $page) Tj ET'),
  ];
  final buffer = StringBuffer('%PDF-1.4\n');
  final offsets = <int>[0];
  for (var index = 0; index < objects.length; index++) {
    offsets.add(buffer.length);
    buffer.write('${index + 1} 0 obj\n${objects[index]}\nendobj\n');
  }
  final start = buffer.length;
  buffer.write('xref\n0 ${offsets.length}\n0000000000 65535 f \n');
  for (final offset in offsets.skip(1)) {
    buffer.write('${offset.toString().padLeft(10, '0')} 00000 n \n');
  }
  buffer.write(
    'trailer\n<< /Size ${offsets.length} /Root 1 0 R >>\nstartxref\n$start\n%%EOF\n',
  );
  return Uint8List.fromList(ascii.encode(buffer.toString()));
}

String _pdfStream(String content) =>
    '<< /Length ${content.length} >>\nstream\n$content\nendstream';

Uint8List _wav() {
  const rate = 8000;
  const samples = rate * 12;
  final data = ByteData(44 + samples * 2);
  final bytes = data.buffer.asUint8List();
  void tag(int offset, String text) =>
      bytes.setRange(offset, offset + 4, ascii.encode(text));
  tag(0, 'RIFF');
  data.setUint32(4, bytes.length - 8, Endian.little);
  tag(8, 'WAVE');
  tag(12, 'fmt ');
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, 1, Endian.little);
  data.setUint16(22, 1, Endian.little);
  data.setUint32(24, rate, Endian.little);
  data.setUint32(28, rate * 2, Endian.little);
  data.setUint16(32, 2, Endian.little);
  data.setUint16(34, 16, Endian.little);
  tag(36, 'data');
  data.setUint32(40, samples * 2, Endian.little);
  for (var sample = 0; sample < samples; sample++) {
    data.setInt16(
      44 + sample * 2,
      (sin(2 * pi * 440 * sample / rate) * 2000).round(),
      Endian.little,
    );
  }
  return bytes;
}
