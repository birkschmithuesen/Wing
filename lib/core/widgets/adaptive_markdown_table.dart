import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:markdown/markdown.dart' as md;

import '../theme/wing_theme.dart';
import 'background_markdown_content.dart';
import 'conversation_reading_scope.dart';

/// A parsed table with one presentation policy across messages and documents.
/// Cells retain their original inline AST rather than round-tripping Markdown.
class AdaptiveMarkdownTable extends StatefulWidget {
  const AdaptiveMarkdownTable({
    super.key,
    required this.table,
    required this.cellBuilder,
  });

  final md.Element table;
  final Widget Function(md.Element cell, bool heading) cellBuilder;

  @override
  State<AdaptiveMarkdownTable> createState() => _TableState();
}

class _TableState extends State<AdaptiveMarkdownTable> {
  final _scroll = ScrollController();
  // Start in table view; content or layout changes must not replace the
  // reader's choice for this mounted table.
  bool _gridPreference = true;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  List<List<md.Element>> _rows(md.Element element) => [
    for (final child in element.children ?? const <md.Node>[])
      if (child is md.Element)
        if (child.tag == 'tr')
          child.children!.whereType<md.Element>().toList()
        else
          ..._rows(child),
  ];

  void _select(bool grid) {
    MarkdownContentWillChange(context).dispatch(context);
    setState(() => _gridPreference = grid);
  }

  Widget _action(
    String label,
    IconData icon,
    bool selected,
    VoidCallback onPressed,
  ) => StudioButtonPress(
    child: IconButton(
      tooltip: label,
      isSelected: selected,
      style: IconButton.styleFrom(
        backgroundColor: selected
            ? Theme.of(context).colorScheme.primary.withValues(alpha: .14)
            : Colors.transparent,
        foregroundColor: selected
            ? Theme.of(context).colorScheme.primary
            : null,
      ),
      icon: Icon(icon, size: 20),
      selectedIcon: Icon(icon, size: 20),
      onPressed: onPressed,
    ),
  );

  @override
  Widget build(BuildContext context) {
    final rows = _rows(widget.table);
    if (rows.isEmpty) return const SizedBox.shrink();
    final columns = rows.map((row) => row.length).reduce(math.max);
    final theme = Theme.of(context);
    final scaler = MediaQuery.textScalerOf(context);
    final style = theme.textTheme.bodyLarge!;
    final widths = List.generate(columns, (column) {
      final texts = rows
          .where((row) => row.length > column)
          .map((row) => row[column].textContent);
      final longest = texts.reduce((a, b) => a.length > b.length ? a : b);
      final painter = TextPainter(
        text: TextSpan(text: longest, style: style),
        textScaler: scaler,
        textDirection: Directionality.of(context),
        maxLines: 1,
      )..layout();
      final width = (painter.width + 24).clamp(
        scaler.scale(80),
        scaler.scale(280),
      );
      painter.dispose();
      return width;
    });
    final naturalWidth = widths.fold<double>(0, (sum, width) => sum + width);
    final reading = ConversationReadingScope.maybeOf(context);
    final headers = rows.first;
    Widget cell(int row, int column, {bool heading = false}) =>
        column < rows[row].length
        ? widget.cellBuilder(rows[row][column], heading)
        : const SizedBox.shrink();

    return LayoutBuilder(
      builder: (context, constraints) {
        final grid = _gridPreference;
        final extra =
            math.max(0.0, constraints.maxWidth - naturalWidth) / columns;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '${rows.length - 1} rows',
                    style: theme.textTheme.labelMedium,
                  ),
                ),
                _action(
                  'Read as stacked rows',
                  Icons.view_agenda_outlined,
                  !grid,
                  () => _select(false),
                ),
                _action(
                  'Read as table',
                  Icons.table_chart_outlined,
                  grid,
                  () => _select(true),
                ),
                if (reading != null)
                  _action(
                    reading.active ? 'Exit reading mode' : 'Enter reading mode',
                    reading.active ? Icons.fullscreen_exit : Icons.fullscreen,
                    reading.active,
                    () {
                      MarkdownContentWillChange(context).dispatch(context);
                      reading.toggle();
                    },
                  ),
              ],
            ),
            if (grid)
              Scrollbar(
                controller: _scroll,
                thumbVisibility: true,
                child: SingleChildScrollView(
                  controller: _scroll,
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Table(
                    columnWidths: {
                      for (var i = 0; i < columns; i++)
                        i: FixedColumnWidth(widths[i] + extra),
                    },
                    defaultVerticalAlignment: TableCellVerticalAlignment.top,
                    border: TableBorder.all(
                      color: theme.colorScheme.outlineVariant,
                    ),
                    children: [
                      for (var r = 0; r < rows.length; r++)
                        TableRow(
                          decoration: r == 0
                              ? BoxDecoration(
                                  color: theme.colorScheme.surfaceContainerLow,
                                )
                              : null,
                          children: [
                            for (var c = 0; c < columns; c++)
                              Padding(
                                padding: const EdgeInsets.all(12),
                                child: cell(r, c, heading: r == 0),
                              ),
                          ],
                        ),
                    ],
                  ),
                ),
              )
            else
              for (var r = 1; r < rows.length; r++)
                Container(
                  padding: const EdgeInsets.symmetric(
                    vertical: 16,
                    horizontal: 4,
                  ),
                  decoration: BoxDecoration(
                    border: Border(
                      top: BorderSide(color: theme.colorScheme.outlineVariant),
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (var c = 0; c < columns; c++) ...[
                        if (c > 0) const SizedBox(height: 14),
                        if (c < headers.length &&
                            headers[c].textContent.trim().isNotEmpty)
                          cell(0, c, heading: true)
                        else
                          Text(
                            'Column ${c + 1}',
                            style: theme.textTheme.labelMedium,
                          ),
                        const SizedBox(height: 6),
                        cell(r, c),
                      ],
                    ],
                  ),
                ),
          ],
        );
      },
    );
  }
}
