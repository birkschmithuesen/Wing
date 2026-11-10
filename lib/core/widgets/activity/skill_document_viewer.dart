import '../studio_error.dart';
import '../selection_viewport.dart';
import 'activity_detail_actions.dart';
import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';
import '../../models/chat_output.dart';
import '../../models/skill_reader.dart';
import '../../presentation/skill_document.dart';
import '../../services/skill_reader_session.dart';
import '../../services/platform_share.dart';
import '../../theme/wing_theme.dart';
import '../markdown_message_content.dart';
import '../resource_filename.dart';

part 'skill_reader_navigation.dart';
part 'skill_reader_activity.dart';

/// The activity captures this factory before pushing its viewer route.
class SkillReaderScope extends InheritedWidget {
  const SkillReaderScope({
    super.key,
    required this.createReader,
    required super.child,
  });
  final SkillReaderSession Function(SkillDocument) createReader;
  static SkillReaderSession Function(SkillDocument)? maybeOf(
    BuildContext context,
  ) => context
      .dependOnInheritedWidgetOfExactType<SkillReaderScope>()
      ?.createReader;
  @override
  bool updateShouldNotify(SkillReaderScope oldWidget) =>
      oldWidget.createReader != createReader;
}

/// One reading surface; the captured session owns API observations and its lease.
class SkillDocumentViewer extends StatefulWidget {
  const SkillDocumentViewer({
    super.key,
    required this.document,
    this.createReader,
    this.loadImage,
    this.onOpenRemoteFile,
    this.actions = const [],
    this.bodyBuilder,
    this.markdown = true,
    this.truncated = false,
  });
  final SkillDocument document;
  final SkillReaderSession Function()? createReader;
  final Future<Uint8List> Function(String)? loadImage;
  final Future<void> Function(ChatOutput)? onOpenRemoteFile;
  final List<ActivityDetailAction> actions;
  final Widget Function(BuildContext, Widget)? bodyBuilder;
  final bool markdown, truncated;
  @override
  State<SkillDocumentViewer> createState() => _SkillDocumentViewerState();
}

class _SkillDocumentViewerState extends State<SkillDocumentViewer> {
  final _scroll = ScrollController();
  final _trigger = GlobalKey();
  SkillReaderSession? _reader;
  List<MarkdownHeadingAnchor> _headings = const [];
  bool _raw = false, _sharing = false;
  String? _openingReference;
  @override
  void initState() {
    super.initState();
    _attach();
  }

  void _attach() {
    _reader = widget.createReader?.call();
    _reader?.addListener(_changed);
    final reader = _reader;
    if (reader != null) unawaited(reader.load());
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void didUpdateWidget(SkillDocumentViewer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.document.rawContent != widget.document.rawContent ||
        oldWidget.document.name != widget.document.name ||
        oldWidget.document.sourcePath != widget.document.sourcePath) {
      _reader?.removeListener(_changed);
      _reader?.dispose();
      _headings = const [];
      _attach();
    }
  }

  @override
  void dispose() {
    _reader?.removeListener(_changed);
    _reader?.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _receivedHeadings(List<MarkdownHeadingAnchor> all) {
    final sections = all.where((h) => h.level == 2).toList();
    if (!mounted ||
        sections.length == _headings.length &&
            List.generate(
              sections.length,
              (i) => sections[i].key == _headings[i].key,
            ).every((v) => v)) {
      return;
    }
    setState(() => _headings = sections);
  }

  String get _payload => _raw || !widget.markdown
      ? widget.document.rawContent
      : widget.document.formattedText;
  Future<void> _share(BuildContext anchor) async {
    if (_sharing) return;
    const key = 'share-skill-content';
    dismissTransientError(anchor, errorKey: key);
    final payload = _payload;
    final box = context.findRenderObject() as RenderBox?;
    setState(() => _sharing = true);
    try {
      await platformShare(
        ShareParams(
          text: payload,
          title: widget.document.name,
          sharePositionOrigin: box == null
              ? null
              : box.localToGlobal(Offset.zero) & box.size,
        ),
      );
    } on PlatformShareBusy catch (error) {
      if (anchor.mounted) {
        showTransientError(
          anchor,
          error.message,
          errorKey: key,
          icon: Icons.share_outlined,
        );
      }
    } catch (_) {
      if (anchor.mounted) {
        showTransientError(
          anchor,
          'Could not share this text. Try again.',
          errorKey: key,
          icon: Icons.share_outlined,
        );
      }
    } finally {
      if (mounted) setState(() => _sharing = false);
    }
  }

  void _notice(String text) => showStudioError(context, text);
  Future<void> _reference(SkillReference file) async {
    if (_openingReference != null) return;
    final reader = _reader;
    if (reader == null) return;
    setState(() => _openingReference = file.path);
    try {
      final received = await reader.openReference(file);
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => SkillDocumentViewer(
            document: SkillDocument.fromReceived(
              name: received.name,
              content: received.content,
              sourcePath: received.path,
            ),
            markdown: received.markdown,
            truncated: received.truncated,
            loadImage: widget.loadImage,
            onOpenRemoteFile: widget.onOpenRemoteFile,
          ),
        ),
      );
    } catch (_) {
      if (mounted) {
        _notice(
          'Could not read this reference. Check the connection and try again.',
        );
      }
    } finally {
      if (mounted) setState(() => _openingReference = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = WingTokens.of(context), document = widget.document;
    final observation = _reader?.observation;
    final category = observation?.category ?? document.category;
    final metadata = [
      ...document.metadata,
      if (category != null) (label: 'Category', value: category),
    ];
    final body = ScrollConfiguration(
      behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
      child: SingleChildScrollView(
        controller: _scroll,
        padding: const EdgeInsets.fromLTRB(8, 12, 8, 108),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (document.description case final purpose?)
              Container(
                key: _trigger,
                margin: const EdgeInsets.only(bottom: 12),
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.primaryContainer,
                  border: Border(
                    left: BorderSide(color: colors.accent, width: 3),
                  ),
                  borderRadius: const BorderRadius.horizontal(
                    right: Radius.circular(6),
                  ),
                ),
                child: Text(
                  purpose,
                  style: colors.typography.body.copyWith(
                    fontSize: 18,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            if (metadata.isNotEmpty || document.tags.isNotEmpty)
              _SkillSurface(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (metadata.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.all(8),
                        child: LayoutBuilder(
                          builder: (context, box) {
                            Widget fact(({String label, String value}) fact) =>
                                Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      fact.label,
                                      style: colors.typography.label.copyWith(
                                        color: colors.muted,
                                      ),
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      fact.value,
                                      style: colors.typography.body.copyWith(
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ],
                                );
                            return Wrap(
                              spacing: 16,
                              runSpacing: 8,
                              children: [
                                for (final value in metadata)
                                  ConstrainedBox(
                                    constraints: BoxConstraints(
                                      maxWidth: box.maxWidth,
                                    ),
                                    child: fact(value),
                                  ),
                              ],
                            );
                          },
                        ),
                      ),
                    if (document.tags.isNotEmpty) ...[
                      if (metadata.isNotEmpty) const _SkillRule(),
                      Padding(
                        padding: const EdgeInsets.all(8),
                        child: Wrap(
                          spacing: 4,
                          runSpacing: 4,
                          children: [
                            for (final tag in document.tags)
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 6,
                                  vertical: 3,
                                ),
                                decoration: BoxDecoration(
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.primaryContainer,
                                  borderRadius: WingRadius.control,
                                ),
                                child: Text(
                                  tag,
                                  style: colors.typography.label.copyWith(
                                    color: colors.accent,
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            if (observation != null && observation.references.isNotEmpty)
              _SkillReferences(
                files: observation.references,
                opening: _openingReference,
                onOpen: _reference,
              ),
            if (_reader != null)
              _SkillActivitySummary(observation: observation),
            _SkillSurface(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 4,
                      vertical: 4,
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        if (widget.markdown)
                          ActivityDetailAction(
                            label: _raw
                                ? 'Show formatted content'
                                : 'Show raw content',
                            icon: _raw
                                ? Icons.article_outlined
                                : Icons.code_rounded,
                            onPressed: () => setState(() => _raw = !_raw),
                          ),
                        Builder(
                          builder: (anchor) => ActivityDetailAction(
                            label: 'Share content',
                            icon: Icons.share_outlined,
                            busy: _sharing,
                            onPressed: _payload.isEmpty
                                ? null
                                : () => _share(anchor),
                          ),
                        ),
                        ToolDetailCopyButton(
                          label: 'Copy content',
                          text: _payload,
                        ),
                      ],
                    ),
                  ),
                  const _SkillRule(),
                  Padding(
                    padding: const EdgeInsets.all(8),
                    child: _raw || !widget.markdown
                        ? viewportSelection(
                            SelectableText(
                              document.rawContent,
                              style: colors.typography.mono,
                            ),
                          )
                        : MarkdownMessageContent(
                            data: document.formattedContent,
                            documentPath: document.sourcePath,
                            loadImage: widget.loadImage,
                            onOpenRemoteFile: widget.onOpenRemoteFile,
                            onHeadings: _receivedHeadings,
                          ),
                  ),
                  if (widget.truncated) ...[
                    const _SkillRule(),
                    Padding(
                      padding: const EdgeInsets.all(8),
                      child: Text(
                        'Partial file returned',
                        style: colors.typography.label.copyWith(
                          color: colors.muted,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
    final navigation = _SkillReaderNavigation(
      scroll: _scroll,
      trigger: _trigger,
      headings: _raw || !widget.markdown ? const [] : _headings,
      child: body,
    );
    return Scaffold(
      appBar: ResourceViewerAppBar(
        context: context,
        inlineActions: true,
        title: document.name,
        target: document.sourcePath,
        resourceLabel: document.name,
        actions: [
          if (widget.actions.isNotEmpty)
            StudioButtonPress(
              child: PopupMenuButton<void>(
                tooltip: 'Skill actions',
                icon: const Icon(Icons.more_vert, size: 18),
                itemBuilder: (_) => [
                  StudioPopupMenuItem<void>(
                    enabled: false,
                    child: Builder(
                      builder: (menuContext) => Wrap(
                        children: [
                          for (final action in widget.actions)
                            ActivityDetailAction(
                              label: action.label,
                              icon: action.icon,
                              busy: action.busy,
                              onPressed: action.onPressed == null
                                  ? null
                                  : () {
                                      Navigator.pop(menuContext);
                                      action.onPressed!();
                                    },
                            ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ToolDetailCopyButton(label: 'Copy skill name', text: document.name),
        ],
      ),
      body: widget.bodyBuilder?.call(context, navigation) ?? navigation,
    );
  }
}

class _SkillSurface extends StatelessWidget {
  const _SkillSurface({required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.only(bottom: 12),
    decoration: BoxDecoration(
      color: WingTokens.of(context).raised,
      border: Border.all(color: WingTokens.of(context).border),
      borderRadius: WingRadius.card,
    ),
    clipBehavior: Clip.antiAlias,
    child: child,
  );
}

class _SkillRule extends StatelessWidget {
  const _SkillRule();
  @override
  Widget build(BuildContext context) =>
      Divider(height: 1, thickness: 1, color: WingTokens.of(context).border);
}

String _skillBytes(int bytes) =>
    bytes < 1024 ? '$bytes B' : '${(bytes / 1024).toStringAsFixed(1)} KB';

/// Bounded reference browsing, independent of the document's scroll position.
class _SkillReferences extends StatefulWidget {
  const _SkillReferences({
    required this.files,
    required this.opening,
    required this.onOpen,
  });
  final List<SkillReference> files;
  final String? opening;
  final Future<void> Function(SkillReference) onOpen;

  @override
  State<_SkillReferences> createState() => _SkillReferencesState();
}

class _SkillReferencesState extends State<_SkillReferences> {
  final _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final files = widget.files, opening = widget.opening;
    final colors = WingTokens.of(context),
        scaler = MediaQuery.textScalerOf(context);
    final hasSizes = files.any((file) => file.bytes != null);
    double lineHeight(TextStyle style) {
      final painter = TextPainter(
        text: TextSpan(text: 'Ag', style: style),
        textScaler: scaler,
        textDirection: Directionality.of(context),
        maxLines: 1,
      )..layout();
      final height = painter.height;
      painter.dispose();
      return height;
    }

    final rowHeight =
        math.max(
          32.0,
          lineHeight(colors.typography.body) +
              (hasSizes ? lineHeight(colors.typography.label) : 0),
        ) +
        16;
    final visible = math.min(5, files.length);
    return _SkillSurface(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.all(8),
            child: Text(
              files.length == 1 ? 'Reference file' : 'Reference files',
              style: colors.typography.label,
            ),
          ),
          const _SkillRule(),
          SizedBox(
            height: rowHeight * visible + visible - 1,
            child: Scrollbar(
              controller: _scroll,
              thumbVisibility: files.length > 5,
              thickness: 3,
              radius: const Radius.circular(2),
              child: ListView.separated(
                controller: _scroll,
                primary: false,
                padding: EdgeInsets.zero,
                itemCount: files.length,
                separatorBuilder: (_, _) => const _SkillRule(),
                itemBuilder: (context, index) {
                  final file = files[index];
                  return SizedBox(
                    height: rowHeight,
                    child: Padding(
                      padding: const EdgeInsets.all(8),
                      child: Row(
                        children: [
                          Icon(
                            Icons.menu_book_outlined,
                            size: 18,
                            color: colors.muted,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                ResourceFilename(
                                  target: file.path,
                                  label: file.name,
                                  style: colors.typography.body,
                                ),
                                if (file.bytes case final bytes?)
                                  Text(
                                    _skillBytes(bytes),
                                    style: colors.typography.label.copyWith(
                                      color: colors.muted,
                                    ),
                                  ),
                              ],
                            ),
                          ),
                          ActivityDetailAction(
                            label: 'Read ${file.name}',
                            icon: Icons.visibility_outlined,
                            busy: opening == file.path,
                            onPressed: opening == null
                                ? () => widget.onOpen(file)
                                : null,
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}
