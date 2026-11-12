/// Offline fixture for the complete HTML file route and actual Android WebView.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:wing/core/screens/html_preview_screen.dart';
import 'package:wing/core/services/remote_files_client.dart';
import 'package:wing/core/theme/wing_theme.dart';

void main() {
  if (!kDebugMode) throw StateError('This fixture requires debug mode.');
  const prefix = '<!doctype html><!--';
  const tail = '''--><html><head>
<meta name="viewport" content="width=device-width, initial-scale=1">
<style>body{font:18px system-ui;margin:24px;color:#1b2d36;background:#f7f7f4}
button{font:inherit;padding:12px}table{border-collapse:collapse;width:100%}
td,th{text-align:left;border-bottom:1px solid #d6e0e1;padding:12px 0}</style>
</head><body><h1 id="large-title">Complete 32 MiB report</h1>
<p>The complete document reached the Android HTML viewer.</p>
<table><tr><th>Report</th><th>Records</th></tr><tr><td>Memory review</td><td>24,842</td></tr></table>
<p><button id="increment">Check interaction</button></p><p>Count: <output id="count">0</output></p>
<script>
document.getElementById('increment').onclick=()=>document.getElementById('count').textContent++;
try{parent.document.body.dataset.escaped='yes'}catch(e){document.body.dataset.parentAccess='blocked'}
try{localStorage.setItem('probe','yes')}catch(e){document.body.dataset.storage='blocked'}
</script></body></html>''';
  final source =
      prefix +
      'x' *
          (maxFilePreviewBytes -
              prefix.length -
              tail.length) +
      tail;
  final bytes = utf8.encode(source);
  if (bytes.length != 32 * 1024 * 1024) {
    throw StateError(
      'Native HTML acceptance requires a complete 32 MiB fixture',
    );
  }
  runApp(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: wingTheme(Brightness.dark),
      home: HtmlPreviewScreen(
        title: 'Large report',
        download: () async =>
            RemoteFileDownload(filename: 'report.html', bytes: bytes),
        share: (_) async {},
      ),
    ),
  );
}
