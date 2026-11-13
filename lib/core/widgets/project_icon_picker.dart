import 'selection_viewport.dart';
import 'studio_form_actions.dart';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/project_icon.dart';
import '../theme/project_icon_glyphs.dart';
import '../theme/wing_theme.dart';
import 'studio_loading.dart';

Future<String?> showProjectIconPicker(
  BuildContext context, {
  required String initialIcon,
  Color? color,
}) {
  FocusManager.instance.primaryFocus?.unfocus();
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Theme.of(context).colorScheme.surfaceContainerLow,
    builder: (_) => StudioLoadingFrame(
      child: ProjectIconPicker(initialIcon: initialIcon, color: color),
    ),
  );
}

/// A local icon draft. Only confirmation publishes the choice to its caller.
class ProjectIconPicker extends StatefulWidget {
  const ProjectIconPicker({super.key, required this.initialIcon, this.color});
  final String initialIcon;
  final Color? color;

  @override
  State<ProjectIconPicker> createState() => _ProjectIconPickerState();
}

class _ProjectIconPickerState extends State<ProjectIconPicker> {
  final _search = TextEditingController();
  final _scroll = ScrollController();
  late String _selected = widget.initialIcon;
  int _category = 0;

  @override
  void dispose() {
    _search.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _changeCategory(int index) {
    setState(() {
      _category = index;
      _search.clear();
    });
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  void _searchChanged() {
    setState(() {});
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  Widget _choice(
    String name, {
    required bool selected,
    required VoidCallback onTap,
    required Key key,
    String? label,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return StudioButtonPress(
      child: IconButton(
        key: key,
        tooltip: label ?? projectIconLabel(name),
        isSelected: selected,
        style: IconButton.styleFrom(
          minimumSize: const Size.square(48),
          shape: RoundedRectangleBorder(borderRadius: WingRadius.control),
          backgroundColor: selected
              ? scheme.primaryContainer
              : Colors.transparent,
          foregroundColor: selected ? scheme.primary : scheme.onSurfaceVariant,
        ),
        onPressed: onTap,
        icon: Icon(ProjectIconGlyphs.of(name), size: 25),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final category = projectIconCategories[_category];
    final searching = _search.text.trim().isNotEmpty;
    final choices = searching
        ? searchProjectIcons(_search.text)
        : category.icons.map((name) => projectIconChoices[name]!).toList();
    final media = MediaQuery.of(context);
    final height = math.min(
      560.0,
      math.max(
        0.0,
        media.size.height - media.viewInsets.bottom - media.padding.top - 24,
      ),
    );
    return Padding(
      padding: EdgeInsets.only(bottom: media.viewInsets.bottom),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: height,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
                child: StudioFormHeader(
                  title: Row(
                    children: [
                      const Expanded(
                        child: Text(
                          'Choose icon',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      StudioButtonPress(
                        child: IconButton(
                          key: const ValueKey('project-icon-reset'),
                          tooltip: 'Use default icon',
                          onPressed: () => setState(() => _selected = ''),
                          icon: const Icon(Icons.restart_alt),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
                child: viewportSelection(
                  TextField(
                    key: const ValueKey('project-icon-search-field'),
                    controller: _search,
                    onChanged: (_) => _searchChanged(),
                    decoration: InputDecoration(
                      hintText: 'Search icons',
                      labelText: 'Search icons',
                      prefixIcon: const Icon(Icons.search),
                      suffixIcon: _search.text.isEmpty
                          ? null
                          : StudioButtonPress(
                              child: IconButton(
                                tooltip: 'Clear icon search',
                                onPressed: () {
                                  _search.clear();
                                  _searchChanged();
                                },
                                icon: const Icon(Icons.close),
                              ),
                            ),
                    ),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Row(
                  children: [
                    for (
                      var index = 0;
                      index < projectIconCategories.length;
                      index++
                    )
                      Expanded(
                        child: _choice(
                          projectIconCategories[index].tabIcon,
                          key: ValueKey(
                            'project-icon-category-${projectIconCategories[index].name}',
                          ),
                          label: projectIconCategories[index].label,
                          selected: index == _category && !searching,
                          onTap: () => _changeCategory(index),
                        ),
                      ),
                  ],
                ),
              ),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 12),
                child: Divider(),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        searching ? 'Search results' : category.label,
                        key: const ValueKey('project-icon-category-label'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Text(
                      '${choices.length}',
                      semanticsLabel: '${choices.length} icons',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
              Expanded(
                child: choices.isEmpty
                    ? SingleChildScrollView(
                        padding: const EdgeInsets.all(12),
                        child: Text(
                          'No icons found. Try another word.',
                          key: const ValueKey('project-icon-empty'),
                        ),
                      )
                    : Scrollbar(
                        controller: _scroll,
                        thumbVisibility: true,
                        child: GridView.builder(
                          key: const ValueKey('project-icon-grid'),
                          controller: _scroll,
                          padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                          gridDelegate:
                              const SliverGridDelegateWithMaxCrossAxisExtent(
                                maxCrossAxisExtent: 64,
                                mainAxisExtent: 48,
                                mainAxisSpacing: 8,
                                crossAxisSpacing: 8,
                              ),
                          itemCount: choices.length,
                          itemBuilder: (_, index) => _choice(
                            choices[index].name,
                            key: ValueKey(
                              'project-icon-${choices[index].name}',
                            ),
                            selected: _selected == choices[index].name,
                            onTap: () =>
                                setState(() => _selected = choices[index].name),
                          ),
                        ),
                      ),
              ),
              const Divider(height: 1),
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 12,
                ),
                child: Row(
                  children: [
                    Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: (widget.color ?? scheme.primary).withValues(
                          alpha: .16,
                        ),
                        borderRadius: WingRadius.control,
                      ),
                      child: Icon(
                        ProjectIconGlyphs.of(_selected),
                        color: widget.color ?? scheme.primary,
                        size: 24,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Tooltip(
                        message: projectIconLabel(_selected),
                        excludeFromSemantics: true,
                        child: Text(
                          projectIconLabel(_selected),
                          key: const ValueKey('project-icon-preview-label'),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    StudioFormActions(
                      onCancel: () => Navigator.pop(context),
                      cancelLabel: 'Cancel icon selection',
                      onConfirm: () => Navigator.pop(context, _selected),
                      confirmKey: const ValueKey('project-icon-confirm'),
                      confirmLabel: 'Use selected icon',
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
