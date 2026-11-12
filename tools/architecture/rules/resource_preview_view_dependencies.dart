import '../cli.dart' as cli;
import '../model.dart';
import '../view_adapter_dependencies.dart';

const id = 'ARCH_RESOURCE_PREVIEW_VIEW_DEPENDENCIES';
const views = {
  'lib/core/screens/html_preview_screen.dart': 'HtmlPreviewScreen',
  'lib/core/screens/pdf_preview_screen.dart': 'PdfPreviewScreen',
  'lib/core/widgets/chat_inline_image.dart': 'ChatInlineImage',
  'lib/core/widgets/user_message_attachment.dart': 'UserMessageAttachmentTile',
};
const _adapters = {
  'lib/core/services/file_open_error_message.dart',
  'lib/core/services/connection_manager.dart',
  'lib/core/services/remote_file_saver.dart',
};

/// Completed previews cannot expose transport errors, delivery or byte codecs.
/// Native reader constructors and Flutter image providers remain route wiring.
/// This namespace check does not establish asynchronous release or byte bounds.
List<Finding> check(Snapshot snapshot) {
  final findings = <Finding>[];
  for (final view in views.entries) {
    findings.addAll(
      checkViewAdapterDependencies(
        snapshot,
        id: id,
        view: view.key,
        viewClass: view.value,
        adapters: _adapters,
        message:
            'Use captured resource readers and typed observations; transport errors and file delivery belong to their owners.',
        missingViewMessage: 'Completed resource preview missing/ambiguous',
        detachedPartMessage:
            'Resource preview part is not declared by its owner',
      ),
    );
    bool exposesCodec(Dependency edge) {
      if (edge.uri == 'dart:convert') return true;
      if (edge.target == null) return false;
      final pending = [Uri(path: edge.target!).normalizePath().path];
      final seen = <String>{};
      while (pending.isNotEmpty) {
        final library = pending.removeLast();
        if (!seen.add(library)) continue;
        for (final source in snapshot.sources.values.where(
          (source) => snapshot.libraries[source.path] == library,
        )) {
          for (final export in source.dependencies.where(
            (edge) => edge.kind == 'export',
          )) {
            if (export.uri == 'dart:convert') return true;
            if (export.target != null) {
              pending.add(Uri(path: export.target!).normalizePath().path);
            }
          }
        }
      }
      return false;
    }

    for (final source in snapshot.sources.values.where(
      (source) => snapshot.libraries[source.path] == view.key,
    )) {
      for (final edge in source.dependencies) {
        if (exposesCodec(edge)) {
          findings.add(
            Finding(
              id,
              source.path,
              edge.line,
              edge.subject,
              'HTML and embedded image decoding belong to resource owners; keep byte codecs outside the completed preview namespace.',
            ),
          );
        }
      }
    }
  }
  return findings..sort();
}

Future<void> main(List<String> arguments) =>
    cli.run([...arguments, '--strict'], {id: check});
