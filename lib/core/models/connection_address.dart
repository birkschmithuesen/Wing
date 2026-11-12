/// A complete gateway Webapp or custom chat base URL. Ports and proxy paths have one owner.
class ConnectionAddress {
  const ConnectionAddress._(this.uri);

  final Uri uri;

  String get url => uri.toString().replaceFirst(RegExp(r'/$'), '');
  String get host => uri.host;
  int get port => uri.port;
  bool get useHttps => uri.scheme == 'https';
  String get path => uri.path == '/' ? '' : uri.path;
  String get socketUrl => uri
      .replace(scheme: useHttps ? 'wss' : 'ws', path: '$path/api/ws')
      .toString();

  static ConnectionAddress parse(String input) {
    final raw = input.trim();
    final uri = Uri.tryParse(raw);
    if (uri == null ||
        !['http', 'https'].contains(uri.scheme) ||
        uri.host.isEmpty ||
        RegExp(r'\s|\\').hasMatch(raw)) {
      throw const FormatException(
        'Enter a complete address, such as https://hermes.example.com.',
      );
    }
    if (uri.userInfo.isNotEmpty || uri.hasQuery || uri.hasFragment) {
      throw const FormatException(
        'Use the base address without embedded credentials, a query or a fragment.',
      );
    }
    if (uri.port < 1 || uri.port > 65535) {
      throw const FormatException('The port must be between 1 and 65535.');
    }
    final host = uri.host.toLowerCase().replaceAll(RegExp(r'[\[\]]'), '');
    if (host == 'localhost' ||
        host.endsWith('.localhost') ||
        host == '0.0.0.0' ||
        host == '::' ||
        host == '::1' ||
        host.startsWith('127.')) {
      throw const FormatException(
        'Use your Hermes computer’s network address. This address does not identify it from your phone.',
      );
    }
    final path = uri.path.replaceFirst(RegExp(r'/+$'), '');
    if (RegExp(r'/(api/ws|v1/chat/completions)$').hasMatch(path)) {
      throw const FormatException(
        'Use the gateway Webapp base address, without /api/ws or /v1/chat/completions.',
      );
    }
    return ConnectionAddress._(uri.replace(path: path));
  }
}
