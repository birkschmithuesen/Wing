import '../widgets/studio_form_actions.dart';
import '../widgets/selection_viewport.dart';
import 'package:wing/core/widgets/studio_loading.dart';
import '../widgets/wing_app_bar.dart';
import '../widgets/studio_error.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/chat_output.dart';
import '../models/app_preferences.dart';
import '../services/chat_outputs_session.dart';
import '../services/file_open_error_message.dart';
import '../services/remote_files_client.dart';
import '../widgets/chat_image_preview.dart';
import '../widgets/read_recovery.dart';
import '../widgets/resource_filename.dart';
import '../theme/wing_theme.dart';
import '../widgets/markdown_code_block.dart';
import '../widgets/markdown_message_content.dart';
import '../widgets/web_output_preview.dart';
import '../widgets/web_link_scope.dart';
import 'pdf_preview_screen.dart';
import 'html_preview_screen.dart';

enum _FileAction { share, save, open, play }

class ChatOutputsScreen extends StatefulWidget {
  final String chatTitle;
  final ChatOutputsSession Function() createSession;
  final ChatOutput? initialOutput;

  const ChatOutputsScreen({
    super.key,
    required this.chatTitle,
    required this.createSession,
    this.initialOutput,
  });

  @override
  State<ChatOutputsScreen> createState() => _ChatOutputsScreenState();
}

class _ChatOutputsScreenState extends State<ChatOutputsScreen> {
  late final ChatOutputsSession _session;
  ChatOutputsObservation get _observation => _session.observation;
  String? _initialError;
  bool _initialOpening = false;
  bool _working = false;

  @override
  void initState() {
    super.initState();
    _session = widget.createSession()..addListener(_changed);
    final initialOutput = widget.initialOutput;
    if (initialOutput == null) {
      _load();
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        unawaited(_openInitial(initialOutput));
      });
    }
  }

  Future<void> _openInitial(ChatOutput output) async {
    if (!mounted || _initialOpening) return;
    setState(() {
      _initialOpening = true;
      _initialError = null;
    });
    try {
      await _preview(output);
      if (mounted && ModalRoute.of(context)?.isCurrent == true) {
        Navigator.of(context).maybePop();
      }
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _initialError = fileOpenErrorMessage(error);
      });
    } finally {
      if (mounted) setState(() => _initialOpening = false);
    }
  }

  void _error(BuildContext context, Object error, {VoidCallback? onRetry}) {
    if (!context.mounted) return;
    final message = fileOpenErrorMessage(error);
    if (onRetry == null) {
      showStudioError(context, message);
      return;
    }
    unawaited(
      showDialog<void>(
        context: context,
        builder: (dialogContext) => StudioDialog(
          content: StudioError(message),
          actions: [
            const StudioButtonPress(child: CloseButton()),
            StudioButtonPress(
              child: IconButton(
                onPressed: () {
                  Navigator.of(dialogContext).pop();
                  onRetry();
                },
                tooltip: 'Retry',
                icon: const Icon(Icons.refresh),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _load({bool refresh = false}) => _session.load(refresh: refresh);
  Future<void> _share(RemoteFileDownload file) => _session.share(file);

  @override
  void dispose() {
    _session.removeListener(_changed);
    _session.dispose();
    super.dispose();
  }

  Future<void> _run(
    Future<void> Function() action, {
    bool offerRetry = false,
  }) async {
    if (_working) return;
    setState(() => _working = true);
    try {
      await action();
    } catch (error) {
      if (mounted) {
        _error(
          context,
          error,
          onRetry: offerRetry && canRetryFileOpen(error)
              ? () => unawaited(_run(action, offerRetry: true))
              : null,
        );
      }
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _preview(ChatOutput output) async {
    final prepared = await _session.prepare(output);
    if (!mounted) return;
    final path = output.path;
    if (prepared.kind == OutputPreviewKind.external) {
      return _session.openLink(
        output.url!,
        WebLinkScope.destinationOf(context),
      );
    }
    if (prepared.kind == OutputPreviewKind.image ||
        prepared.kind == OutputPreviewKind.svg) {
      final imageFile = prepared.file;
      final uri = prepared.uri;
      if (prepared.kind == OutputPreviewKind.svg) {
        final source = prepared.svgSource!;
        await Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => WebOutputPreview(
              source: source,
              format: WebOutputFormat.svg,
              title: output.label,
              resourceTarget: path,
              actionLabel: 'Save or share',
              onAction: (anchor) async {
                const key = 'share-svg-output';
                dismissTransientError(anchor, errorKey: key);
                try {
                  await _share(imageFile!);
                } catch (error) {
                  if (anchor.mounted) {
                    showTransientError(
                      anchor,
                      fileOpenErrorMessage(error),
                      errorKey: key,
                      icon: Icons.share_outlined,
                    );
                  }
                }
              },
            ),
          ),
        );
        return;
      }
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => ChatImagePreview(
            uri: uri,
            bytes: imageFile?.bytes,
            title: output.label,
            resourceTarget: path,
            actionLabel: imageFile == null
                ? 'Open in browser'
                : 'Save or share',
            actionIcon: imageFile == null
                ? Icons.open_in_new
                : Icons.share_outlined,
            onOpenExternal: () async {
              try {
                if (imageFile != null) {
                  await _share(imageFile);
                } else {
                  await _session.openLink(
                    output.url!,
                    WebLinkDestination.externalBrowser,
                  );
                }
                return null;
              } catch (error) {
                return fileOpenErrorMessage(error);
              }
            },
          ),
        ),
      );
      return;
    }
    if (prepared.kind == OutputPreviewKind.html) {
      return _previewHtml(output, path!);
    }
    final preview = prepared.text!;
    final canOpen = prepared.canOpen;
    final canPlay = prepared.canPlay;
    final isPdf = prepared.isPdf;
    final isMarkdown = prepared.isMarkdown;
    var delivering = false;
    String? deliveryError;
    var showMarkdownSource = false;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => StatefulBuilder(
          builder: (previewContext, setPreviewState) {
            Future<void> deliverFile(_FileAction action) async {
              if (!mounted || delivering) return;
              setPreviewState(() {
                delivering = true;
                deliveryError = null;
              });
              try {
                final file = await _session.download(path!);
                if (!mounted || !previewContext.mounted) return;
                switch (action) {
                  case _FileAction.share:
                    await _share(file);
                  case _FileAction.save:
                    final saved = await _session.save(file);
                    if (saved && previewContext.mounted) {
                      ScaffoldMessenger.of(previewContext).showSnackBar(
                        const SnackBar(content: Text('File saved')),
                      );
                    }
                  case _FileAction.open:
                    final opened = await _session.open(
                      file,
                      mimeType: preview.mimeType,
                    );
                    if (!opened && previewContext.mounted) {
                      setPreviewState(
                        () => deliveryError =
                            'No compatible app was found. Use Save or share instead.',
                      );
                    }
                  case _FileAction.play:
                    final theme = Theme.of(previewContext);
                    final opened = await _session.play(
                      file,
                      title: output.label,
                      mimeType: preview.mimeType,
                      appearance: {
                        'dark': theme.brightness == Brightness.dark ? 1 : 0,
                        'surface': theme.colorScheme.surface.toARGB32(),
                        'text': theme.colorScheme.onSurface.toARGB32(),
                        'accent': theme.colorScheme.primary.toARGB32(),
                        'onAccent': theme.colorScheme.onPrimary.toARGB32(),
                        'error': theme.colorScheme.error.toARGB32(),
                      },
                    );
                    if (!opened && previewContext.mounted) {
                      setPreviewState(
                        () => deliveryError =
                            'Media playback is unavailable on this device. Try Open in app or Save or share.',
                      );
                    }
                }
              } catch (error) {
                if (previewContext.mounted) {
                  setPreviewState(
                    () => deliveryError = action == _FileAction.play
                        ? 'This media could not be played on this device.'
                        : fileOpenErrorMessage(error),
                  );
                }
              } finally {
                if (previewContext.mounted) {
                  setPreviewState(() => delivering = false);
                }
              }
            }

            final actions = <Widget>[
              if (isMarkdown) ...[
                ResourceViewerAction(
                  label: showMarkdownSource
                      ? 'Show formatted content'
                      : 'Show Raw content',
                  icon: showMarkdownSource
                      ? Icons.notes_outlined
                      : Icons.code_rounded,
                  onPressed: () => setPreviewState(
                    () => showMarkdownSource = !showMarkdownSource,
                  ),
                ),
              ],
              ResourceViewerAction(
                label: 'Download',
                icon: Icons.download_outlined,
                onPressed: delivering
                    ? null
                    : () => deliverFile(_FileAction.save),
              ),
              if (isMarkdown) ...[
                ResourceViewerAction(
                  label: 'Share file',
                  icon: Icons.share_outlined,
                  onPressed: delivering
                      ? null
                      : () => deliverFile(_FileAction.share),
                ),
                Builder(
                  builder: (anchor) => ResourceViewerAction(
                    label: 'Copy content',
                    icon: Icons.copy_outlined,
                    onPressed: () async {
                      dismissTransientError(anchor, errorKey: 'copy-output');
                      try {
                        await Clipboard.setData(
                          ClipboardData(text: preview.text),
                        );
                      } catch (_) {
                        if (anchor.mounted) {
                          showTransientError(
                            anchor,
                            'Could not copy this text. Try again.',
                            errorKey: 'copy-output',
                            icon: Icons.copy_outlined,
                          );
                        }
                      }
                    },
                  ),
                ),
              ],
            ];

            return Scaffold(
              appBar: ResourceViewerAppBar(
                context: previewContext,
                title: output.label,
                target: preview.path,
                actions: actions,
              ),
              body: ListView(
                padding: const EdgeInsets.all(WingSpacing.sm),
                children: [
                  if (deliveryError case final error?)
                    StudioError(error, icon: Icons.insert_drive_file_outlined),
                  if (preview.binary)
                    Text(
                      canOpen
                          ? 'Open this file in a compatible app, or save/share a copy.'
                          : 'Use Save or share to open this file in another app.',
                    )
                  else if (!isMarkdown) ...[
                    if (preview.truncated)
                      const Text(
                        'Preview shortened by Hermes. Save the file to read it all.',
                      ),
                    MarkdownCodeBlock(
                      code: preview.text,
                      language: preview.language,
                    ),
                  ] else
                    DecoratedBox(
                      key: const ValueKey('resource-document-sheet'),
                      decoration: BoxDecoration(
                        color: WingTokens.of(previewContext).raised,
                        borderRadius: WingRadius.card,
                        border: Border.all(
                          color: WingTokens.of(previewContext).border,
                        ),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.all(WingSpacing.sm),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            if (preview.truncated)
                              const Text(
                                'Preview shortened by Hermes. Save the file to read it all.',
                              ),
                            if (!showMarkdownSource)
                              MarkdownMessageContent(
                                data: preview.text,
                                documentPath: preview.path,
                                initialFragment: output.fragment,
                                onOpenRemoteFile: _preview,
                                loadImage: (path) async =>
                                    (await _session.download(path)).bytes,
                                onDownloadRemoteFile: (output) async =>
                                    _session.save(
                                      await _session.download(output.path!),
                                    ),
                              )
                            else
                              viewportSelection(
                                SelectableText(
                                  preview.text,
                                  style: WingTokens.of(
                                    previewContext,
                                  ).typography.mono,
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  if (isPdf || canPlay || canOpen || !isMarkdown)
                    Wrap(
                      spacing: WingSpacing.sm,
                      runSpacing: WingSpacing.sm,
                      children: [
                        if (isPdf)
                          ResourceViewerAction(
                            icon: Icons.picture_as_pdf_outlined,
                            label: 'Read PDF',
                            onPressed: delivering
                                ? null
                                : () async {
                                    if (delivering) return;
                                    setPreviewState(() {
                                      delivering = true;
                                      deliveryError = null;
                                    });
                                    try {
                                      await Navigator.of(previewContext).push(
                                        MaterialPageRoute<void>(
                                          builder: (_) => PdfPreviewScreen(
                                            title: output.label,
                                            resourceTarget: path,
                                            download: () =>
                                                _session.download(path!),
                                          ),
                                        ),
                                      );
                                    } finally {
                                      if (previewContext.mounted) {
                                        setPreviewState(
                                          () => delivering = false,
                                        );
                                      }
                                    }
                                  },
                          ),
                        if (canPlay)
                          ResourceViewerAction(
                            icon: Icons.play_arrow,
                            label: 'Play media',
                            onPressed: delivering
                                ? null
                                : () => deliverFile(_FileAction.play),
                          ),
                        if (canOpen)
                          ResourceViewerAction(
                            icon: Icons.open_in_new,
                            label: 'Open in app',
                            onPressed: delivering
                                ? null
                                : () => deliverFile(_FileAction.open),
                          ),
                        if (!isMarkdown)
                          ResourceViewerAction(
                            icon: Icons.share_outlined,
                            label: 'Save or share',
                            onPressed: delivering
                                ? null
                                : () => deliverFile(_FileAction.share),
                          ),
                      ],
                    ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  Future<void> _previewHtml(ChatOutput output, String path) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => HtmlPreviewScreen(
          title: output.label,
          resourceTarget: path,
          download: () => _session.download(path),
          share: _share,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => ReadRecovery(
    shouldRetry: () =>
        widget.initialOutput == null &&
        !_working &&
        !_observation.loading &&
        _observation.retryable,
    retry: () => _load(refresh: _observation.retryRefresh),
    child: _buildContent(context),
  );

  Widget _buildContent(BuildContext context) {
    if (widget.initialOutput != null) {
      return Scaffold(
        appBar: ResourceViewerAppBar(
          context: context,
          title: widget.initialOutput!.label,
          target: widget.initialOutput!.path,
        ),
        body: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_initialError == null)
                  const StudioPageLoading.waiting(label: 'Loading outputs')
                else ...[
                  StudioError(_initialError!),
                  const SizedBox(height: 12),
                  StudioButtonPress(
                    child: TextButton(
                      onPressed: _initialOpening
                          ? null
                          : () =>
                                unawaited(_openInitial(widget.initialOutput!)),
                      child: const Text('Try again'),
                    ),
                  ),
                ],
                StudioButtonPress(
                  child: TextButton(
                    onPressed: () => Navigator.of(context).maybePop(),
                    child: const Text('Back to chat'),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }
    final outputs = _observation.outputs;
    return Scaffold(
      appBar: WingAppBar(
        context: context,
        title: Text(
          'Outputs · ${widget.chatTitle}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          StudioButtonPress(
            child: IconButton(
              tooltip: 'Refresh outputs',
              icon: const Icon(Icons.refresh),
              onPressed: _working || _observation.loading
                  ? null
                  : () => _load(refresh: true),
            ),
          ),
        ],
      ),
      body: StudioLoadingRegion(
        available: _observation.hasObservation && !_working,
        busy: _working,
        label: _working ? 'Opening output' : 'Loading outputs',
        child: Column(
          children: [
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('Open a file or link shared in this chat.'),
            ),
            Expanded(
              child: _observation.loading && !_observation.hasObservation
                  ? StudioPageLoading.waiting(label: 'Loading outputs')
                  : outputs.isEmpty
                  ? Center(
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.all(24),
                        child: _observation.error != null
                            ? StudioError(_observation.error!)
                            : Text(
                                (!_observation.hasMore
                                    ? 'No files or links found in this chat.'
                                    : 'No outputs found in the recent part of this chat. Load older outputs to look further back.'),
                              ),
                      ),
                    )
                  : ListView.builder(
                      itemCount: outputs.length,
                      itemBuilder: (context, index) {
                        final output = outputs[index];
                        return StudioButtonPress(
                          child: ListTile(
                            leading: Icon(switch (output.kind) {
                              ChatOutputKind.image => Icons.image_outlined,
                              ChatOutputKind.file =>
                                Icons.insert_drive_file_outlined,
                              ChatOutputKind.link => Icons.link,
                            }),
                            title: Text(
                              output.label,
                              maxLines: 1,
                              softWrap: false,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: Text(
                              output.target,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                            onTap: _working
                                ? null
                                : () => _run(
                                    () => _preview(output),
                                    offerRetry: true,
                                  ),
                            trailing: output.path == null
                                ? null
                                : StudioButtonPress(
                                    child: IconButton(
                                      tooltip: 'Save or share ${output.label}',
                                      icon: const Icon(Icons.ios_share),
                                      onPressed: _working
                                          ? null
                                          : () => _run(
                                              () async => _share(
                                                await _session.download(
                                                  output.path!,
                                                ),
                                              ),
                                            ),
                                    ),
                                  ),
                          ),
                        );
                      },
                    ),
            ),
            if (!_observation.loading || outputs.isNotEmpty)
              SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (outputs.isNotEmpty &&
                          (_observation.error != null || _observation.hasMore))
                        _observation.error != null
                            ? StudioError(_observation.error!)
                            : Text(
                                'Recent outputs shown. Load older outputs to look further back.',
                              ),
                      if (_observation.error != null)
                        StudioButtonPress(
                          child: TextButton(
                            onPressed: _working || _observation.loading
                                ? null
                                : () =>
                                      _load(refresh: _observation.retryRefresh),
                            child: const Text('Try again'),
                          ),
                        )
                      else if (_observation.hasMore)
                        StudioButtonPress(
                          child: TextButton(
                            onPressed: _working || _observation.loading
                                ? null
                                : () => _load(),
                            child: const Text('Load older outputs'),
                          ),
                        ),
                      if (_observation.error != null && outputs.isEmpty)
                        StudioButtonPress(
                          child: TextButton(
                            onPressed: () => Navigator.of(context).maybePop(),
                            child: const Text('Back to chat'),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
