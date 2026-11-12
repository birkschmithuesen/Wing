import 'selection_viewport.dart';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../theme/wing_theme.dart';
import 'compact_switch.dart';

class ChatMenuChoice {
  const ChatMenuChoice(
    this.id,
    this.label,
    this.icon, {
    this.selected = false,
    this.enabled = true,
    this.toggle,
    this.dividerBefore = false,
    this.fontStyle = FontStyle.normal,
  });
  final String id, label;
  final Widget icon;
  final bool selected, enabled, dividerBefore;
  final bool? toggle;
  final FontStyle fontStyle;
}

/// An anchored, bounded menu. The choices scroll independently of the heading
/// and Clear/Done controls. Each row retains a 48 dp native activation target.
/// A live menu borrows [choicesChanges]; explicit null captures immutable
/// choices. The observation is captured when this route opens.
Future<void> showChatListMenu(
  BuildContext anchor, {
  required String title,
  required List<ChatMenuChoice> Function() choices,
  required Listenable? choicesChanges,
  required void Function(String) onSelected,
  bool multiple = false,
  int maxVisible = 5,
  VoidCallback? onClear,
  String? searchHint,
}) async {
  final box = anchor.findRenderObject()! as RenderBox;
  final rect = box.localToGlobal(Offset.zero) & box.size;
  var query = '';
  await showGeneralDialog<void>(
    context: anchor,
    barrierDismissible: true,
    barrierColor: Colors.transparent,
    barrierLabel: 'Dismiss $title',
    requestFocus: true,
    transitionDuration: Duration.zero,
    pageBuilder: (context, _, _) => LayoutBuilder(
      builder: (context, constraints) => StatefulBuilder(
        builder: (context, update) {
          Widget buildChoices(BuildContext context) {
            final tokens = WingTokens.of(context);
            final media = MediaQuery.of(
              context,
            ).copyWith(size: constraints.biggest);
            final width = math.min(
              media.size.width - 16,
              media.textScaler.scale(280).clamp(280.0, 340.0),
            );
            final rowHeight = math.max(48.0, media.textScaler.scale(20) + 24);
            final allOptions = choices();
            final options = allOptions
                .where((option) => option.label.toLowerCase().contains(query))
                .toList();
            final headerHeight = math.max(
              searchHint == null ? 38.0 : 48.0,
              media.textScaler.scale(18) + 12,
            );
            final labelStyle = Theme.of(
              context,
            ).textTheme.bodyMedium!.copyWith(fontSize: 14, height: 1.3);
            final heights = options.map((option) {
              final painter =
                  TextPainter(
                    text: TextSpan(
                      text: option.label,
                      style: labelStyle.copyWith(fontStyle: option.fontStyle),
                    ),
                    textDirection: Directionality.of(context),
                    textScaler: media.textScaler,
                    // A toggle's action label must stay complete; ordinary
                    // choice labels retain their two-line summary treatment.
                    maxLines: option.toggle == null ? 2 : null,
                  )..layout(
                    maxWidth: width - 56 - (option.toggle == null ? 0 : 48),
                  );
              final height = math.max(
                rowHeight,
                math.max(
                  painter.height + 12,
                  option.toggle == null ? 0.0 : 60.0,
                ),
              );
              painter.dispose();
              return height;
            }).toList();
            final contentHeight =
                heights.fold<double>(0, (a, b) => a + b) +
                options.where((o) => o.dividerBefore).length * 5;
            final desired =
                (searchHint == null
                    ? math.min(contentHeight, maxVisible * rowHeight)
                    : math.min(math.max(1, allOptions.length), maxVisible) *
                          rowHeight) +
                headerHeight +
                (multiple ? 48 : 0) +
                10;
            final safeTop = media.padding.top + 8;
            final safeBottom =
                media.size.height -
                math.max(media.padding.bottom, media.viewInsets.bottom) -
                8;
            final anchorBottom = rect.bottom.clamp(safeTop, safeBottom);
            final anchorTop = rect.top.clamp(safeTop, safeBottom);
            final below = safeBottom - anchorBottom - 4;
            final above = anchorTop - safeTop - 4;
            final placeBelow =
                below >= math.min(desired, 240) || below >= above;
            final height = math.min(
              desired,
              math.max(0.0, placeBelow ? below : above),
            );
            final top = placeBelow ? anchorBottom + 4 : anchorTop - height - 4;
            return Stack(
              children: [
                Positioned(
                  left: rect.left.clamp(8.0, media.size.width - width - 8),
                  top: top.clamp(safeTop, safeBottom),
                  width: width,
                  height: height,
                  child: Shortcuts(
                    shortcuts: const {
                      SingleActivator(LogicalKeyboardKey.escape):
                          DismissIntent(),
                    },
                    child: Actions(
                      actions: {
                        DismissIntent: CallbackAction<DismissIntent>(
                          onInvoke: (_) {
                            Navigator.pop(context);
                            return null;
                          },
                        ),
                      },
                      child: FocusTraversalGroup(
                        child: Material(
                          color: tokens.raised,
                          elevation: 6,
                          shape: RoundedRectangleBorder(
                            borderRadius: WingRadius.card,
                            side: BorderSide(color: tokens.border),
                          ),
                          clipBehavior: Clip.antiAlias,
                          child: Padding(
                            padding: const EdgeInsets.all(5),
                            child: Column(
                              children: [
                                SizedBox(
                                  height: headerHeight,
                                  child: Row(
                                    children: [
                                      const SizedBox(width: 8),
                                      Expanded(
                                        child: searchHint != null
                                            ? viewportSelection(
                                                TextField(
                                                  key: const ValueKey(
                                                    'chat-menu-search',
                                                  ),
                                                  style: labelStyle,
                                                  textInputAction:
                                                      TextInputAction.search,
                                                  autocorrect: false,
                                                  enableSuggestions: false,
                                                  decoration: InputDecoration(
                                                    hintText: searchHint,
                                                    isDense: true,
                                                    contentPadding:
                                                        const EdgeInsets.symmetric(
                                                          horizontal: 8,
                                                          vertical: 8,
                                                        ),
                                                    prefixIcon: const Icon(
                                                      Icons.search,
                                                      size: 16,
                                                    ),
                                                    prefixIconConstraints:
                                                        const BoxConstraints(
                                                          minWidth: 28,
                                                        ),
                                                  ),
                                                  onChanged: (value) =>
                                                      update(() {
                                                        query = value
                                                            .trim()
                                                            .toLowerCase();
                                                      }),
                                                ),
                                              )
                                            : Text(
                                                title,
                                                style: TextStyle(
                                                  fontSize: 13,
                                                  color: tokens.muted,
                                                  fontWeight: FontWeight.w600,
                                                ),
                                              ),
                                      ),
                                      StudioButtonPress(
                                        child: IconButton(
                                          tooltip: 'Close $title',
                                          icon: const Icon(
                                            Icons.close,
                                            size: 16,
                                          ),
                                          onPressed: () =>
                                              Navigator.pop(context),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                Expanded(
                                  child: options.isEmpty
                                      ? Center(
                                          child: Text(
                                            'No matches',
                                            style: labelStyle.copyWith(
                                              color: tokens.muted,
                                            ),
                                          ),
                                        )
                                      : Scrollbar(
                                          child: ListView.builder(
                                            key: ValueKey(query),
                                            padding: EdgeInsets.zero,
                                            itemCount: options.length,
                                            itemBuilder: (context, index) {
                                              final option = options[index];
                                              return Column(
                                                mainAxisSize: MainAxisSize.min,
                                                children: [
                                                  if (option.dividerBefore)
                                                    Divider(
                                                      height: 5,
                                                      color: tokens.border,
                                                    ),
                                                  Semantics(
                                                    selected: option.selected,
                                                    toggled: option.toggle,
                                                    enabled: option.enabled,
                                                    child: Material(
                                                      color: option.selected
                                                          ? Theme.of(context)
                                                                .colorScheme
                                                                .primaryContainer
                                                          : Colors.transparent,
                                                      borderRadius:
                                                          WingRadius.control,
                                                      child: StudioButtonPress(
                                                        child: InkWell(
                                                          autofocus: index == 0,
                                                          key: ValueKey(
                                                            'chat-menu-${option.id}',
                                                          ),
                                                          borderRadius:
                                                              WingRadius
                                                                  .control,
                                                          onTap: !option.enabled
                                                              ? null
                                                              : () {
                                                                  if (!multiple) {
                                                                    Navigator.pop(
                                                                      context,
                                                                    );
                                                                  }
                                                                  onSelected(
                                                                    option.id,
                                                                  );
                                                                  if (multiple &&
                                                                      context
                                                                          .mounted) {
                                                                    update(
                                                                      () {},
                                                                    );
                                                                  }
                                                                },
                                                          child: ConstrainedBox(
                                                            constraints:
                                                                BoxConstraints(
                                                                  minHeight:
                                                                      heights[index],
                                                                ),
                                                            child: Padding(
                                                              padding:
                                                                  const EdgeInsets.symmetric(
                                                                    horizontal:
                                                                        8,
                                                                    vertical: 6,
                                                                  ),
                                                              child: Row(
                                                                children: [
                                                                  IconTheme(
                                                                    data: IconThemeData(
                                                                      size: 18,
                                                                      color:
                                                                          option
                                                                              .enabled
                                                                          ? tokens.muted
                                                                          : Theme.of(
                                                                              context,
                                                                            ).disabledColor,
                                                                    ),
                                                                    child: SizedBox(
                                                                      width: 22,
                                                                      child: option
                                                                          .icon,
                                                                    ),
                                                                  ),
                                                                  const SizedBox(
                                                                    width: 8,
                                                                  ),
                                                                  Expanded(
                                                                    child: Text(
                                                                      option
                                                                          .label,
                                                                      maxLines:
                                                                          option.toggle ==
                                                                              null
                                                                          ? 2
                                                                          : null,
                                                                      overflow:
                                                                          option.toggle ==
                                                                              null
                                                                          ? TextOverflow.ellipsis
                                                                          : TextOverflow.clip,
                                                                      style: TextStyle(
                                                                        fontStyle:
                                                                            option.fontStyle,
                                                                        fontSize:
                                                                            14,
                                                                        height:
                                                                            1.3,
                                                                        color:
                                                                            option.enabled
                                                                            ? tokens.onSurface
                                                                            : Theme.of(
                                                                                context,
                                                                              ).disabledColor,
                                                                      ),
                                                                    ),
                                                                  ),
                                                                  if (option
                                                                          .toggle !=
                                                                      null)
                                                                    ExcludeSemantics(
                                                                      child: IgnorePointer(
                                                                        child: CompactSwitch(
                                                                          value:
                                                                              option.toggle!,
                                                                          onChanged:
                                                                              (_) {},
                                                                        ),
                                                                      ),
                                                                    ),
                                                                ],
                                                              ),
                                                            ),
                                                          ),
                                                        ),
                                                      ),
                                                    ),
                                                  ),
                                                ],
                                              );
                                            },
                                          ),
                                        ),
                                ),
                                if (multiple)
                                  SizedBox(
                                    height: 48,
                                    child: Row(
                                      children: [
                                        if (onClear != null)
                                          StudioButtonPress(
                                            child: IconButton(
                                              tooltip: 'Clear filters',
                                              onPressed: () {
                                                onClear();
                                                update(() {});
                                              },
                                              icon: const Icon(
                                                Icons.filter_alt_off_outlined,
                                              ),
                                            ),
                                          ),
                                        const Spacer(),
                                        StudioButtonPress(
                                          child: IconButton(
                                            tooltip: 'Close filters',
                                            onPressed: () =>
                                                Navigator.pop(context),
                                            icon: const Icon(Icons.close),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            );
          }

          if (choicesChanges case final changes?) {
            return ListenableBuilder(
              listenable: changes,
              builder: (context, _) => buildChoices(context),
            );
          }
          return buildChoices(context);
        },
      ),
    ),
  );
}
