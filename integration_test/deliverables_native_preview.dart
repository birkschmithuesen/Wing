/// Disposable, offline Android fixture for the deliverable reader and save picker.
library;

import 'package:wing/core/services/chat_outputs_session.dart';

import 'package:wing/core/models/transcript_message.dart';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:wing/core/models/chat_output.dart';
import 'package:wing/core/screens/chat_outputs_screen.dart';
import 'package:wing/core/services/remote_file_saver.dart';
import 'package:wing/core/services/remote_files_client.dart';
import 'package:wing/core/theme/wing_theme.dart';
import 'package:wing/core/widgets/profile_message.dart';

const _name = 'WING_DELIVERABLE_QA.md';
const _path = '/srv/reports/$_name';
const _source =
    '# Full bank analysis\n\nThe report is ready.\n\n'
    '| Priority | Action |\n| --- | --- |\n| P1 | Retention repair |\n\n'
    '## Next step\n\nReview the holdout before changing policy.\n';

void main() {
  if (!kDebugMode) throw StateError('This fixture requires debug mode.');
  runApp(const _Preview());
}

class _Preview extends StatefulWidget {
  const _Preview();
  @override
  State<_Preview> createState() => _PreviewState();
}

class _PreviewState extends State<_Preview> {
  bool dark = true;
  bool enlarged = false;
  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: wingTheme(dark ? Brightness.dark : Brightness.light),
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(
        context,
      ).copyWith(textScaler: TextScaler.linear(enlarged ? 2 : 1)),
      child: child!,
    ),
    home: Builder(
      builder: (context) => Scaffold(
        appBar: AppBar(
          title: const Text('Deliverable QA'),
          actions: [
            IconButton(
              tooltip: 'Toggle theme',
              onPressed: () => setState(() => dark = !dark),
              icon: const Icon(Icons.brightness_6),
            ),
            IconButton(
              tooltip: 'Toggle text size',
              onPressed: () => setState(() => enlarged = !enlarged),
              icon: const Icon(Icons.text_fields),
            ),
          ],
        ),
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: ProfileMessage(
            message: TranscriptMessage.fromRow(const {
              'role': 'assistant',
              'content':
                  'The analysis is ready.\n\n**Deliverable**\n\nMEDIA:$_path\n\nReview the report before the next step.',
            }),
            onOpenRemoteFile: (output) => _open(context, output),
            onDownloadRemoteFile: (_) => saveRemoteFile(
              RemoteFileDownload(filename: _name, bytes: utf8.encode(_source)),
            ),
          ),
        ),
      ),
    ),
  );

  Future<void> _open(BuildContext context, ChatOutput output) =>
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => ChatOutputsScreen(
            chatTitle: 'Deliverable QA',
            initialOutput: output,
            createSession: () => ChatOutputsSession(
              loadHistory: (_) async =>
                  throw StateError('Direct preview must not load Outputs'),
              download: (_) async => RemoteFileDownload(
                filename: _name,
                bytes: utf8.encode(_source),
              ),
              readText: (_) async => const RemoteTextPreview(
                path: _path,
                text: _source,
                language: 'markdown',
                mimeType: 'text/markdown',
                binary: false,
                truncated: false,
              ),
            ),
          ),
        ),
      );
}
