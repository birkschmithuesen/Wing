/// A resource's compact display name, never its I/O identity.
///
/// Filesystem targets are literal: percent signs, query characters and hashes
/// are allowed in filenames. Only actual HTTP(S) targets use URI path syntax.
String resourceFileName(String target) {
  final uri = Uri.tryParse(target);
  if (uri != null && (uri.scheme == 'https' || uri.scheme == 'http')) {
    return uri.pathSegments.where((part) => part.isNotEmpty).lastOrNull ??
        uri.host;
  }
  return target
          .split(RegExp(r'[\\/]'))
          .where((part) => part.isNotEmpty)
          .lastOrNull ??
      target;
}
