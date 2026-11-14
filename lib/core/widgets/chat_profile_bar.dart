import 'package:flutter/material.dart';

import '../models/hermes_profile.dart';
import '../models/profile_colors.dart';
import '../services/profile_colors_session.dart';
import '../theme/profile_colors.dart';
import '../theme/wing_theme.dart';

/// At most five profile squares are visible; additional profiles scroll inside.
class ChatProfileBar extends StatefulWidget {
  const ChatProfileBar({
    super.key,
    required this.profiles,
    required this.selectedProfiles,
    required this.onSelected,
    required this.onOpenBotChat,
    required this.createColors,
    this.unservedProfiles = const <String>{},
  });

  final List<HermesProfile> profiles;
  final Set<String> selectedProfiles;
  final ValueChanged<String> onSelected;
  final ValueChanged<String> onOpenBotChat;
  final ProfileColorsSession Function() createColors;

  /// Profile names the connected gateway permanently refused; shown disabled
  /// instead of selectable.
  final Set<String> unservedProfiles;

  @override
  State<ChatProfileBar> createState() => _ChatProfileBarState();
}

class _ChatProfileBarState extends State<ChatProfileBar> {
  late ProfileColorsSession _colors;

  @override
  void initState() {
    super.initState();
    _colors = widget.createColors();
    _colors.updateProfiles(widget.profiles.map((profile) => profile.name));
  }

  @override
  void didUpdateWidget(ChatProfileBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.createColors != oldWidget.createColors) {
      _colors.dispose();
      _colors = widget.createColors();
    }
    _colors.updateProfiles(widget.profiles.map((profile) => profile.name));
  }

  @override
  void dispose() {
    _colors.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      ValueListenableBuilder<ProfileColorsState>(
        valueListenable: _colors.state,
        builder: _build,
      );

  Widget _build(BuildContext context, ProfileColorsState state, Widget? child) {
    final tokens = WingTokens.of(context);
    final ordered = [...widget.profiles]..sort(HermesProfile.compareForDisplay);
    return Align(
      alignment: Alignment.centerRight,
      child: SizedBox(
        width: 5 * 24,
        height: 48,
        child: LayoutBuilder(
          builder: (context, constraints) => SingleChildScrollView(
            key: const ValueKey('chat-profile-scroll'),
            scrollDirection: Axis.horizontal,
            child: ConstrainedBox(
              constraints: BoxConstraints(minWidth: constraints.maxWidth),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  for (final profile in ordered)
                    Builder(
                      builder: (context) {
                        final served = !widget.unservedProfiles.contains(
                          profile.name,
                        );
                        final selected = widget.selectedProfiles.contains(
                          profile.name,
                        );
                        final color =
                            profileChoiceColor(
                              profile.name,
                              state.profiles[profile.name]?.displayChoice,
                            ) ??
                            tokens.muted;
                        final hint = !served
                            ? 'Not served by this gateway'
                            : selected
                            ? 'Clear profile filter'
                            : 'Filter chats by ${profile.label}';
                        return Semantics(
                          button: true,
                          selected: selected,
                          enabled: served,
                          label: profile.label,
                          hint: served
                              ? '$hint. Long press to open Bot chat'
                              : hint,
                          excludeSemantics: true,
                          onTap: served
                              ? () => widget.onSelected(profile.name)
                              : null,
                          onLongPress: served
                              ? () => widget.onOpenBotChat(profile.name)
                              : null,
                          child: Tooltip(
                            triggerMode: TooltipTriggerMode.manual,
                            message: served
                                ? '${profile.label} · $hint · Long press to open Bot chat'
                                : '${profile.label} · $hint',
                            child: StudioButtonPress(
                              child: TextButton(
                                key: ValueKey('chat-profile-${profile.name}'),
                                style: TextButton.styleFrom(
                                  fixedSize: const Size(24, 48),
                                  minimumSize: const Size(24, 48),
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 2,
                                    vertical: 14,
                                  ),
                                  tapTargetSize:
                                      MaterialTapTargetSize.shrinkWrap,
                                  visualDensity: VisualDensity.standard,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: WingRadius.control,
                                  ),
                                ),
                                onPressed: served
                                    ? () => widget.onSelected(profile.name)
                                    : null,
                                onLongPress: served
                                    ? () => widget.onOpenBotChat(profile.name)
                                    : null,
                                child: Opacity(
                                  opacity: !served ? .3 : (selected ? 1 : .55),
                                  child: Container(
                                    width: 20,
                                    height: 20,
                                    decoration: BoxDecoration(
                                      color: color.withValues(
                                        alpha: selected ? .30 : .22,
                                      ),
                                      borderRadius: BorderRadius.circular(3),
                                    ),
                                    foregroundDecoration: selected
                                        ? BoxDecoration(
                                            border: Border.all(
                                              color: color,
                                              width: 1.5,
                                              strokeAlign:
                                                  BorderSide.strokeAlignOutside,
                                            ),
                                            borderRadius: BorderRadius.circular(
                                              3,
                                            ),
                                          )
                                        : null,
                                    child: Center(
                                      child: profile.isDefault
                                          ? Icon(
                                              Icons.home_outlined,
                                              size: 14,
                                              color: color,
                                            )
                                          : Text(
                                              profile.label.characters.first
                                                  .toUpperCase(),
                                              style: TextStyle(
                                                color: color,
                                                fontSize: 9,
                                                fontWeight: FontWeight.w600,
                                              ),
                                            ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
