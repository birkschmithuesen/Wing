import 'studio_error.dart';
import 'package:flutter/material.dart';

import '../models/hermes_profile.dart';
import '../models/profile_colors.dart';
import '../services/profile_colors_session.dart';
import '../theme/profile_colors.dart';
import '../theme/wing_theme.dart';

/// The same direct profile choices in Chats and Administration.
class ProfileSelector extends StatefulWidget {
  const ProfileSelector({
    super.key,
    required this.profiles,
    required this.selectedProfile,
    required this.onSelected,
    required this.createColors,
    this.padding = const EdgeInsets.symmetric(horizontal: 16),
    this.trailing,
  });

  final List<HermesProfile> profiles;
  final String? selectedProfile;
  final ValueChanged<String>? onSelected;
  final ProfileColorsSession Function() createColors;
  final EdgeInsetsGeometry padding;
  final Widget? trailing;

  @override
  State<ProfileSelector> createState() => _ProfileSelectorState();
}

class _ProfileSelectorState extends State<ProfileSelector> {
  final _selected = GlobalKey();
  late ProfileColorsSession _colors;
  static const _colorNames = [
    'Red',
    'Orange',
    'Yellow',
    'Lime',
    'Green',
    'Spring',
    'Cyan',
    'Azure',
    'Blue',
    'Violet',
    'Magenta',
    'Rose',
  ];

  Future<void> _chooseColor(BuildContext anchor, HermesProfile profile) async {
    final picker = _colors.beginChoice(profile.name);
    if (picker == null) return;
    final errorKey = ('profile-color', profile.name);
    dismissTransientError(anchor, errorKey: errorKey);
    try {
      final choice = await showModalBottomSheet<ProfileColorChoice>(
        context: context,
        showDragHandle: true,
        isScrollControlled: true,
        useSafeArea: true,
        builder: (sheetContext) => ValueListenableBuilder<ProfileColorsState>(
          valueListenable: picker.state,
          builder: (sheetContext, state, _) {
            final tokens = WingTokens.of(sheetContext);
            final fact = picker.fact;
            return SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Color for ${profile.label}',
                    style: Theme.of(sheetContext).textTheme.titleLarge,
                  ),
                  if (fact.error ?? fact.notice case final feedback?)
                    StudioError(feedback, icon: Icons.palette_outlined),
                  if (fact.reloadVisible)
                    StudioButtonPress(
                      child: TextButton(
                        onPressed: fact.reload == null
                            ? null
                            : () async {
                                await fact.reload!();
                              },
                        child: Text(
                          fact.reloading
                              ? 'Reloading colors…'
                              : 'Reload colors',
                        ),
                      ),
                    ),
                  const SizedBox(height: 16),
                  GridView.builder(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    itemCount: desktopProfileSwatches.length,
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 4,
                          mainAxisSpacing: 8,
                          crossAxisSpacing: 8,
                          childAspectRatio: 1.3,
                        ),
                    itemBuilder: (context, index) {
                      final color = desktopProfileSwatches[index];
                      final choice = ProfileColorChoice.values[index + 1];
                      final isSelected = fact.selected == choice;
                      return Semantics(
                        label: _colorNames[index],
                        selected: isSelected,
                        button: true,
                        enabled: fact.canChoose,
                        onTap: fact.canChoose
                            ? () => Navigator.pop(sheetContext, choice)
                            : null,
                        child: Opacity(
                          opacity: fact.canChoose ? 1 : .45,
                          child: ExcludeSemantics(
                            child: StudioButtonPress(
                              child: TextButton(
                                key: ValueKey('profile-color-$index'),
                                onPressed: fact.canChoose
                                    ? () => Navigator.pop(sheetContext, choice)
                                    : null,
                                style: TextButton.styleFrom(
                                  padding: EdgeInsets.zero,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: WingRadius.control,
                                    side: BorderSide(
                                      color: isSelected
                                          ? tokens.accent
                                          : tokens.border,
                                      width: isSelected ? 2 : 1,
                                    ),
                                  ),
                                ),
                                child: Center(
                                  child: Container(
                                    width: 32,
                                    height: 32,
                                    decoration: BoxDecoration(
                                      color: color,
                                      shape: BoxShape.circle,
                                    ),
                                    child: isSelected
                                        ? Icon(
                                            Icons.check,
                                            size: 18,
                                            color:
                                                ThemeData.estimateBrightnessForColor(
                                                      color,
                                                    ) ==
                                                    Brightness.dark
                                                ? Colors.white
                                                : Colors.black,
                                          )
                                        : null,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                  const SizedBox(height: 12),
                  StudioButtonPress(
                    child: ListTile(
                      key: const ValueKey('profile-color-automatic'),
                      enabled: fact.canChoose,
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(
                        Icons.auto_awesome_outlined,
                        color: tokens.muted,
                      ),
                      title: const Text('Automatic color'),
                      trailing: fact.selected == ProfileColorChoice.automatic
                          ? const Icon(Icons.check)
                          : null,
                      onTap: fact.canChoose
                          ? () => Navigator.pop(
                              sheetContext,
                              ProfileColorChoice.automatic,
                            )
                          : null,
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      );
      if (choice == null) return;
      final error = await picker.choose(choice);
      if (anchor.mounted && error != null) {
        showTransientError(
          anchor,
          error,
          errorKey: errorKey,
          icon: Icons.palette_outlined,
        );
      }
    } finally {
      picker.dispose();
    }
  }

  @override
  void initState() {
    super.initState();
    _colors = widget.createColors();
    _colors.updateProfiles(widget.profiles.map((profile) => profile.name));
    _revealSelection();
  }

  @override
  void didUpdateWidget(ProfileSelector oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.createColors != oldWidget.createColors) {
      _colors.dispose();
      _colors = widget.createColors();
    }
    _colors.updateProfiles(widget.profiles.map((profile) => profile.name));
    if (widget.selectedProfile != oldWidget.selectedProfile ||
        widget.profiles != oldWidget.profiles) {
      _revealSelection();
    }
  }

  @override
  void dispose() {
    _colors.dispose();
    super.dispose();
  }

  void _revealSelection() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final selectedContext = _selected.currentContext;
      final target = selectedContext?.findRenderObject();
      if (selectedContext != null && target != null) {
        // Only reveal horizontally; never move the enclosing page's position.
        Scrollable.of(
          selectedContext,
        ).position.ensureVisible(target, alignment: .5);
      }
    });
  }

  @override
  Widget build(
    BuildContext context,
  ) => ValueListenableBuilder<ProfileColorsState>(
    valueListenable: _colors.state,
    builder: (context, state, _) => SizedBox(
      key: const ValueKey('profile-selector'),
      height: 48 + (MediaQuery.textScalerOf(context).scale(14) - 14),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: widget.padding,
        child: Row(
          children: [
            for (final profile in widget.profiles)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Center(
                  child: Builder(
                    builder: (anchor) => GestureDetector(
                      onLongPress: () => _chooseColor(anchor, profile),
                      child: StudioButtonPress(
                        child: TextButton(
                          key: ValueKey('profile-${profile.name}'),
                          style:
                              TextButton.styleFrom(
                                minimumSize: const Size(48, 36),
                                tapTargetSize: MaterialTapTargetSize.padded,
                                visualDensity: VisualDensity.standard,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                ),
                                foregroundColor: _profileColor(profile.name),
                                backgroundColor: _profileColor(profile.name)
                                    .withValues(
                                      alpha:
                                          widget.selectedProfile == profile.name
                                          ? 0.22
                                          : 0.09,
                                    ),
                                shape: RoundedRectangleBorder(
                                  borderRadius: WingRadius.control,
                                ),
                              ).copyWith(
                                side: WidgetStateProperty.resolveWith((states) {
                                  if (states.contains(WidgetState.focused)) {
                                    return BorderSide(
                                      color: Theme.of(
                                        context,
                                      ).colorScheme.primary,
                                      width: 3,
                                    );
                                  }
                                  return BorderSide(
                                    color: _profileColor(
                                      profile.name,
                                    ).withValues(alpha: 0.28),
                                  );
                                }),
                              ),
                          onPressed: widget.onSelected == null
                              ? null
                              : () => widget.onSelected!(profile.name),
                          child: Semantics(
                            key: widget.selectedProfile == profile.name
                                ? _selected
                                : null,
                            selected: widget.selectedProfile == profile.name,
                            child: Text(
                              profile.label,
                              style: const TextStyle(
                                fontWeight: FontWeight.w600,
                                fontSize: 14,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            if (widget.trailing != null) Center(child: widget.trailing!),
          ],
        ),
      ),
    ),
  );

  Color _profileColor(String name) {
    final color = profileChoiceColor(
      name,
      _colors.state.value.profiles[name]?.displayChoice,
    );
    if (color == null) return WingTokens.of(context).muted;
    final hsl = HSLColor.fromColor(color);
    return hsl
        .withLightness(
          Theme.of(context).brightness == Brightness.dark ? .68 : .34,
        )
        .toColor();
  }
}
