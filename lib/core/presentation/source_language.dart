/// Language evidence for tool file receipts, which supply a path but no grammar.
/// Explicit fence and file-preview languages go directly to the highlighter.
String? sourceLanguageForPath(String? path) {
  if (path == null) return null;
  final filename = path.replaceAll('\\', '/').split('/').last.toLowerCase();
  if (filename == 'dockerfile') return 'dockerfile';
  if (filename == 'makefile') return 'makefile';
  final dot = filename.lastIndexOf('.');
  if (dot < 0) return null;
  return switch (filename.substring(dot + 1)) {
    'py' || 'pyw' => 'python',
    'sh' || 'bash' || 'zsh' => 'bash',
    'graphql' || 'gql' => 'graphql',
    'ps1' => 'powershell',
    'bat' || 'cmd' => 'dos',
    'js' || 'mjs' || 'cjs' || 'jsx' => 'javascript',
    'ts' || 'tsx' => 'typescript',
    'json' => 'json',
    'yaml' || 'yml' => 'yaml',
    'toml' => 'toml',
    'html' || 'htm' || 'xml' || 'svg' => 'xml',
    'css' => 'css',
    'sql' => 'sql',
    'dart' => 'dart',
    'kt' || 'kts' => 'kotlin',
    'java' => 'java',
    'rs' => 'rust',
    'go' => 'go',
    'rb' => 'ruby',
    'c' || 'h' => 'c',
    'cc' || 'cpp' || 'hpp' => 'cpp',
    'swift' => 'swift',
    'r' => 'r',
    'lua' => 'lua',
    'php' => 'php',
    'ini' || 'conf' => 'ini',
    _ => null,
  };
}
