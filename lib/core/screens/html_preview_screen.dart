import 'package:wing/core/theme/wing_theme.dart';
import 'package:wing/core/widgets/studio_loading.dart';
import 'dart:async';

import 'package:flutter/material.dart';

import '../services/owned_remote_files.dart';
import '../services/remote_files_client.dart';
import '../widgets/studio_error.dart';
import '../widgets/resource_filename.dart';
import '../widgets/web_output_preview.dart';

/// Route wiring and rendering for a captured, complete HTML reader.
class HtmlPreviewScreen extends StatefulWidget {
  final String title;
  final String? resourceTarget;
  final Future<RemoteFileDownload> Function() download;
  final Future<void> Function(RemoteFileDownload) share;

  const HtmlPreviewScreen({
    super.key,
    required this.title,
    this.resourceTarget,
    required this.download,
    required this.share,
  });

  @override
  State<HtmlPreviewScreen> createState() => _HtmlPreviewScreenState();
}

class _HtmlPreviewScreenState extends State<HtmlPreviewScreen> {
  late final _reader = HtmlPreviewReader(
    download: widget.download,
    share: widget.share,
  );

  @override
  void initState() {
    super.initState();
    unawaited(_reader.load());
  }

  Future<void> _share(BuildContext anchor) async {
    const key = 'share-html-output';
    dismissTransientError(anchor, errorKey: key);
    final error = await _reader.share();
    if (anchor.mounted && error != null) {
      showTransientError(
        anchor,
        error,
        errorKey: key,
        icon: Icons.share_outlined,
      );
    }
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
      if (observation.source != null) {
        return WebOutputPreview(
          source: observation.source!,
          format: WebOutputFormat.html,
          title: widget.title,
          resourceTarget: widget.resourceTarget,
          actionLabel: 'Save or share',
          onAction: _share,
        );
      }
      return Scaffold(
        appBar: ResourceViewerAppBar(
          context: context,
          title: widget.title,
          target: widget.resourceTarget,
        ),
        body: SafeArea(
          child: Center(
            child: observation.loading
                ? const StudioPageLoading.waiting(label: 'Loading preview')
                : SingleChildScrollView(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        StudioError(observation.error!),
                        const SizedBox(height: 12),
                        if (!observation.hasFile)
                          StudioButtonPress(
                            child: OutlinedButton(
                              onPressed: _reader.load,
                              child: const Text('Try again'),
                            ),
                          )
                        else
                          Builder(
                            builder: (anchor) => ResourceViewerAction(
                              onPressed: observation.sharing
                                  ? null
                                  : () => _share(anchor),
                              icon: observation.sharing
                                  ? Icons.hourglass_top
                                  : Icons.share_outlined,
                              label: observation.sharing
                                  ? 'Preparing share'
                                  : 'Save or share',
                            ),
                          ),
                      ],
                    ),
                  ),
          ),
        ),
      );
    },
  );
}
