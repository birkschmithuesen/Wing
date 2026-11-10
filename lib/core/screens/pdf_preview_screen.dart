import 'package:wing/core/theme/wing_theme.dart';
import 'package:wing/core/widgets/studio_loading.dart';
import '../widgets/studio_error.dart';
import 'dart:async';

import 'package:flutter/material.dart';

import '../services/pdf_preview_service.dart';
import '../services/remote_files_client.dart';
import '../widgets/resource_filename.dart';

class PdfPreviewScreen extends StatefulWidget {
  final String title;
  final String? resourceTarget;
  final Future<RemoteFileDownload> Function() download;
  final PdfPreviewService service;

  const PdfPreviewScreen({
    super.key,
    required this.title,
    this.resourceTarget,
    required this.download,
    this.service = const PdfPreviewService(),
  });

  @override
  State<PdfPreviewScreen> createState() => _PdfPreviewScreenState();
}

class _PdfPreviewScreenState extends State<PdfPreviewScreen> {
  late final _reader = widget.service.createReader(widget.download);

  @override
  void initState() {
    super.initState();
    unawaited(_reader.load());
  }

  @override
  void dispose() {
    _reader.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _reader,
    builder: (context, _) {
      final observation = _reader.observation;
      return Scaffold(
        appBar: ResourceViewerAppBar(
          context: context,
          title: widget.title,
          target: widget.resourceTarget,
        ),
        body: SafeArea(
          child: Center(
            child: observation.loading
                ? const StudioPageLoading.waiting(label: 'Loading PDF')
                : observation.error != null
                ? SingleChildScrollView(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        StudioError(observation.error!),
                        const SizedBox(height: 12),
                        StudioButtonPress(
                          child: OutlinedButton(
                            onPressed: () => _reader.load(),
                            child: const Text('Retry'),
                          ),
                        ),
                      ],
                    ),
                  )
                : InteractiveViewer(
                    key: ValueKey(observation.page),
                    minScale: 1,
                    maxScale: 5,
                    child: Image.memory(
                      observation.pageImage!,
                      fit: BoxFit.contain,
                      semanticLabel: 'PDF page ${observation.page + 1}',
                      errorBuilder: (_, _, _) => const StudioError(
                        'This page could not be displayed. Go back for file options.',
                      ),
                    ),
                  ),
          ),
        ),
        bottomNavigationBar: observation.pageCount == null
            ? null
            : SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: Row(
                    children: [
                      ResourceViewerAction(
                        label: 'Previous page',
                        onPressed: observation.loading || observation.page == 0
                            ? null
                            : () => _reader.showPage(observation.page - 1),
                        icon: Icons.chevron_left,
                      ),
                      Expanded(
                        child: Text(
                          'Page ${observation.page + 1} of ${observation.pageCount!}',
                          textAlign: TextAlign.center,
                        ),
                      ),
                      ResourceViewerAction(
                        label: 'Next page',
                        onPressed:
                            observation.loading ||
                                observation.page + 1 >= observation.pageCount!
                            ? null
                            : () => _reader.showPage(observation.page + 1),
                        icon: Icons.chevron_right,
                      ),
                    ],
                  ),
                ),
              ),
      );
    },
  );
}
