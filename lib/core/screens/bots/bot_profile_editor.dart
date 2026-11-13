import '../../widgets/selection_viewport.dart';
import '../../widgets/studio_form_actions.dart';
import 'package:wing/core/theme/wing_theme.dart';
import 'package:wing/core/widgets/studio_loading.dart';
import 'package:flutter/material.dart';
import '../../models/bots.dart';
import '../../services/bot_profile_edit_session.dart';
import '../../theme/profile_colors.dart';
import '../../widgets/bot_avatar.dart';
import '../../widgets/studio_error.dart';
import '../../widgets/wing_app_bar.dart';

class BotProfileEditor extends StatefulWidget {
  const BotProfileEditor({super.key, required this.createSession});
  final BotProfileEditSession Function() createSession;
  @override
  State<BotProfileEditor> createState() => _BotProfileEditorState();
}

class _BotProfileEditorState extends State<BotProfileEditor>
    with WidgetsBindingObserver {
  late final _session = widget.createSession();
  late final _title = TextEditingController(text: _session.title);
  final _prompt = TextEditingController();
  bool _allowPop = false;
  bool _leaving = false;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _session.addListener(_changed);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncVisibility();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) => _syncVisibility();
  void _syncVisibility() {
    final state = WidgetsBinding.instance.lifecycleState;
    _session.setVisible(
      (state == null || state == AppLifecycleState.resumed) &&
          ModalRoute.isCurrentOf(context) != false,
    );
  }

  void _changed() {
    if (mounted) {
      if (_title.text != _session.title) _title.text = _session.title;
      setState(() {});
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _session.removeListener(_changed);
    _session.dispose();
    _title.dispose();
    _prompt.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: _allowPop || !_session.dirty && !_session.busy && !_session.saving,
    onPopInvokedWithResult: (didPop, _) async {
      if (didPop || _session.busy || _leaving) return;
      _leaving = true;
      if (await _session.flush()) {
        if (mounted) {
          setState(() => _allowPop = true);
          Navigator.pop(this.context, true);
        }
        _leaving = false;
        return;
      }
      if (!mounted) return;
      final discard = await showDialog<bool>(
        context: this.context,
        builder: (context) => StudioDialog(
          title: const Text('Discard edits?'),
          actions: [
            StudioFormActions(
              onCancel: () => Navigator.pop(context, false),
              onConfirm: () => Navigator.pop(context, true),
              confirmLabel: 'Discard edits',
              confirmIcon: Icons.delete_outline,
              destructive: true,
            ),
          ],
        ),
      );
      if (mounted && discard == true) {
        setState(() => _allowPop = true);
        Navigator.pop(this.context);
      }
      _leaving = false;
    },
    child: Scaffold(
      appBar: WingAppBar(
        context: context,
        title: const Text('Edit bot'),
        actions: [
          StudioButtonPress(
            child: IconButton(
              tooltip: 'Reload saved appearance',
              onPressed: _session.busy || _session.saving
                  ? null
                  : _session.reload,
              icon: const Icon(Icons.refresh),
            ),
          ),
        ],
      ),
      body: StudioLoadingRegion(
        available: !_session.busy,
        busy: _session.busy || _session.saving,
        label: 'Saving bot appearance',
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text(
              '${_session.bot.instance} · ${_session.bot.profile.name}',
              style: Theme.of(context).textTheme.bodySmall,
            ),

            if (_session.error != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    StudioError(_session.error!),
                    if (!_session.conflicted && _session.dirty)
                      StudioButtonPress(
                        child: IconButton(
                          tooltip: 'Retry saving appearance',
                          onPressed: _session.busy || _session.saving
                              ? null
                              : _session.flush,
                          icon: const Icon(Icons.replay),
                        ),
                      ),
                  ],
                ),
              ),
            if (_session.needsReview && _session.error == null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Row(
                  children: [
                    const Expanded(
                      child: Text('Review your edits before retrying.'),
                    ),
                    StudioButtonPress(
                      child: IconButton(
                        tooltip: 'Retry saving appearance',
                        onPressed: _session.busy || _session.saving
                            ? null
                            : _session.flush,
                        icon: const Icon(Icons.replay),
                      ),
                    ),
                  ],
                ),
              ),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 24),
              child: Center(
                child: BotAvatar(
                  name: _session.bot.profile.name,
                  shape: _session.shape,
                  color: _session.color,
                  image: _session.image,
                  size: 88,
                ),
              ),
            ),
            viewportSelection(
              TextField(
                controller: _title,
                enabled: !_session.busy,
                textCapitalization: TextCapitalization.words,
                decoration: InputDecoration(
                  labelText: 'Bot name',
                  errorText: _session.title.trim().isEmpty
                      ? 'Give your bot a name.'
                      : null,
                ),
                onChanged: (text) => _session.change(title: text),
              ),
            ),
            const SizedBox(height: 24),
            Text('Shape', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final shape in botShapes)
                  StudioButtonPress(
                    child: IconButton(
                      tooltip: shape,
                      isSelected: _session.shape == shape,
                      style: IconButton.styleFrom(
                        backgroundColor: _session.shape == shape
                            ? Theme.of(context).colorScheme.primaryContainer
                            : null,
                      ),
                      onPressed: _session.busy
                          ? null
                          : () => _session.change(shape: shape),
                      icon: BotAvatar(
                        name: _session.bot.profile.name,
                        shape: shape,
                        color: _session.color,
                        size: 32,
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 20),
            Text('Color', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 8),
            Wrap(
              spacing: 4,
              children: [
                for (var i = 0; i < desktopProfileSwatches.length; i++)
                  StudioButtonPress(
                    child: IconButton(
                      tooltip: 'Color ${i + 1}',
                      isSelected:
                          BotAvatar.resolveColor(
                            _session.color,
                            _session.bot.profile.name,
                          ) ==
                          desktopProfileSwatches[i],
                      onPressed: _session.busy
                          ? null
                          : () => _session.change(
                              color:
                                  '#${desktopProfileSwatches[i].toARGB32().toRadixString(16).substring(2)}',
                            ),
                      icon: Icon(
                        Icons.circle,
                        color: desktopProfileSwatches[i],
                        size: 28,
                      ),
                      selectedIcon: Stack(
                        alignment: Alignment.center,
                        children: [
                          Icon(
                            Icons.circle,
                            color: desktopProfileSwatches[i],
                            size: 28,
                          ),
                          Icon(
                            Icons.check,
                            size: 18,
                            color:
                                desktopProfileSwatches[i].computeLuminance() >
                                    .4
                                ? Colors.black
                                : Colors.white,
                          ),
                        ],
                      ),
                    ),
                  ),
                StudioButtonPress(
                  child: IconButton(
                    tooltip: 'Match profile color',
                    onPressed: _session.busy
                        ? null
                        : () => _session.change(color: ''),
                    icon: const Icon(Icons.restart_alt),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Image',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                ),
                StudioButtonPress(
                  child: IconButton(
                    tooltip: 'Upload avatar',
                    onPressed: _session.busy || _session.saving
                        ? null
                        : _session.pickImage,
                    icon: const Icon(Icons.upload_outlined),
                  ),
                ),
                StudioButtonPress(
                  child: IconButton(
                    tooltip: 'Remove avatar',
                    onPressed: _session.busy ? null : _session.removeImage,
                    icon: const Icon(Icons.image_not_supported_outlined),
                  ),
                ),
              ],
            ),
            viewportSelection(
              TextField(
                controller: _prompt,
                enabled: !_session.busy,
                minLines: 2,
                maxLines: 4,
                decoration: InputDecoration(
                  labelText: 'Describe an avatar',
                  hintText: 'A friendly midnight-blue owl',
                  suffixIcon: StudioButtonPress(
                    child: IconButton(
                      tooltip: 'Generate avatar',
                      onPressed: _session.busy || _session.saving
                          ? null
                          : () => _session.generate(_prompt.text),
                      icon: const Icon(Icons.auto_awesome_outlined),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Generation uses this profile’s image provider. Upload PNG, JPEG or WebP, up to 2 MB.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    ),
  );
}
