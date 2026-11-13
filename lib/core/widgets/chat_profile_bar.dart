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
  });

  final List<HermesProfile> profiles;
  final Set<String> selectedProfiles;
  final ValueChanged<String> onSelected;
  final ValueChanged<String> onOpenBotChat;
  final ProfileColorsSession Function() createColors;

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
                        final selected = widget.selectedProfiles.contains(
                          profile.name,
                        );
                        final color =
                            profileChoiceColor(
                              profile.name,
                              state.profiles[profile.name]?.displayChoice,
                            ) ??
                            tokens.muted;
                        final hint = selected
                            ? 'Clear profile filter'
                            : 'Filter chats by ${profile.label}';
                        return Semantics(
                          button: true,
                          selected: selected,
                          label: profile.label,
                          hint: '$hint. Long press to open Bot chat',
                          excludeSemantics: true,
                          onTap: () => widget.onSelected(profile.name),
                          onLongPress: () => widget.onOpenBotChat(profile.name),
                          child: Tooltip(
                            triggerMode: TooltipTriggerMode.manual,
                            message:
                                '${profile.label} · $hint · Long press to open Bot chat',
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
                                onPressed: () =>
                                    widget.onSelected(profile.name),
                                onLongPress: () =>
                                    widget.onOpenBotChat(profile.name),
                                child: Opacity(
                                  opacity: selected ? 1 : .55,
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
