import 'dart:io';
import 'dart:convert';

import 'package:analyzer/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/element/type.dart';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/theme/wing_theme.dart';
import 'package:wing/core/widgets/studio_selection_tile.dart';
import 'package:wing/core/widgets/studio_select.dart';
import 'package:wing/core/widgets/markdown_message_content.dart';
import 'package:wing/core/widgets/studio_task_marker.dart';

import 'helpers/pump_markdown_widget.dart';
import '../tools/architecture/dart_sdk.dart';

class _ButtonPressCoverage extends RecursiveAstVisitor<void> {
  final missing = <String>[];
  static const controls = {
    'ButtonStyleButton',
    'IconButton',
    'TextButton',
    'OutlinedButton',
    'FilledButton',
    'ElevatedButton',
    'FloatingActionButton',
    'CupertinoButton',
    'InkWell',
    'InkResponse',
    'PopupMenuButton',
    'PopupMenuItem',
    'ActionChip',
    'ChoiceChip',
    'FilterChip',
    'InputChip',
    'Tab',
    'BackButton',
    'CloseButton',
    'DropdownButtonFormField',
  };

  bool studio(InstanceCreationExpression node, String name) {
    final type = node.staticType;
    return type is InterfaceType &&
        type.element.name == name &&
        type.element.library.firstFragment.source.fullName ==
            '${Directory.current.absolute.path}/lib/core/theme/wing_theme.dart';
  }

  @override
  void visitInstanceCreationExpression(InstanceCreationExpression node) {
    final type = node.staticType;
    if (type is InterfaceType &&
        !(studio(node, 'StudioPopupMenuItem') ||
            studio(node, 'StudioCheckedPopupMenuItem'))) {
      final classes = [type, ...type.element.allSupertypes];
      final native = classes
          .where(
            (t) =>
                t.element.library.uri.toString().startsWith(
                  'package:flutter/',
                ) &&
                (controls.contains(t.element.name) ||
                    t.element.name == 'ListTile'),
          )
          .toList();
      if (native.isNotEmpty) {
        final callbacks = node.argumentList.arguments
            .whereType<NamedExpression>()
            .map((arg) => arg.name.label.name)
            .toSet();
        final passiveRow =
            native.first.element.name == 'ListTile' &&
            callbacks.intersection({'onTap', 'onLongPress'}).isEmpty;
        AstNode child = node;
        while (child.parent is ConditionalExpression ||
            child.parent is ParenthesizedExpression) {
          child = child.parent!;
        }
        final argument = child.parent;
        final parent = argument?.parent?.parent;
        final wrapped =
            argument is NamedExpression &&
            {'child', 'entry'}.contains(argument.name.label.name) &&
            parent is InstanceCreationExpression &&
            (studio(parent, 'StudioButtonPress') ||
                studio(parent, 'StudioCheckedPopupMenuItem'));
        if (!passiveRow && !wrapped) {
          missing.add('${native.first.element.name}@${node.offset}');
        }
      }
    }
    super.visitInstanceCreationExpression(node);
  }
}

class _SelectionTickCoverage extends RecursiveAstVisitor<void> {
  final missing = <String>[];

  @override
  void visitInstanceCreationExpression(InstanceCreationExpression node) {
    final type = node.staticType;
    if (type is InterfaceType) {
      for (final candidate in [type, ...type.element.allSupertypes]) {
        if (!candidate.element.library.uri.toString().startsWith(
          'package:flutter/',
        )) {
          continue;
        }
        final argument = switch (candidate.element.name) {
          'ChoiceChip' || 'FilterChip' || 'InputChip' => 'showCheckmark',
          'SegmentedButton' => 'showSelectedIcon',
          _ => null,
        };
        if (argument == null) continue;
        final supplied = node.argumentList.arguments
            .whereType<NamedExpression>()
            .where((entry) => entry.name.label.name == argument);
        if (supplied.isEmpty ||
            supplied.single.expression is! BooleanLiteral ||
            (supplied.single.expression as BooleanLiteral).value) {
          missing.add('${candidate.element.name}@$argument');
        }
        break;
      }
    }
    super.visitInstanceCreationExpression(node);
  }
}

void main() {
  test(
    'all authored action controls use the shared Studio press',
    () async {
      final root = Directory.current.absolute.path;
      final roles =
          (jsonDecode(
                    File(
                      '$root/tools/architecture/roles.json',
                    ).readAsStringSync(),
                  )
                  as Map<String, dynamic>)['files']
              as Map<String, dynamic>;
      final directory = Directory('$root/build/button-migration')
        ..createSync(recursive: true);
      final fixtureDirectory = directory.createTempSync('case-');
      final fixture = File('${fixtureDirectory.path}/coverage_fixture.dart');
      fixture.writeAsStringSync('''
import 'package:flutter/material.dart' as m;
import 'package:wing/core/theme/wing_theme.dart';
typedef AliasButton = m.IconButton;
class IconButton {}
class HiddenButton extends m.IconButton {
  const HiddenButton() : super(onPressed: null, icon: const m.Icon(m.Icons.close));
}
void examples(bool choose) {
  AliasButton(onPressed: null, icon: const m.Icon(m.Icons.close));
  const HiddenButton();
  StudioButtonPress(child: m.IconButton(onPressed: null, icon: const m.Icon(m.Icons.close)));
  StudioButtonPress(child: choose
      ? AliasButton(onPressed: null, icon: const m.Icon(m.Icons.close))
      : const HiddenButton());
  StudioButtonPress(child: (choose
      ? (m.IconButton.filled(onPressed: null, icon: const m.Icon(m.Icons.close)))
      : m.IconButton.outlined(onPressed: null, icon: const m.Icon(m.Icons.close))));
  choose
      ? AliasButton(onPressed: null, icon: const m.Icon(m.Icons.close))
      : const HiddenButton();
  IconButton();
}
''');
      final contexts = AnalysisContextCollection(
        includedPaths: ['$root/lib', fixture.path],
        sdkPath: dartSdkPath(root),
      );
      try {
        final probe = await contexts
            .contextFor(fixture.path)
            .currentSession
            .getResolvedUnit(fixture.path);
        expect(probe, isA<ResolvedUnitResult>());
        final proof = _ButtonPressCoverage();
        (probe as ResolvedUnitResult).unit.accept(proof);
        expect(
          proof.missing.length,
          4,
          reason:
              'Detect unwrapped aliases, subclasses and branches; accept wrapped conditional children and unrelated names',
        );
        final files = Directory('$root/lib')
            .listSync(recursive: true)
            .whereType<File>()
            .where((file) => file.path.endsWith('.dart'))
            .where(
              (file) =>
                  roles[file.path.substring(root.length + 1)]?['role'] ==
                  'view',
            )
            .toList();
        expect(
          files,
          isNotEmpty,
          reason: 'The production view census must resolve.',
        );
        for (final file in files) {
          final result = await contexts
              .contextFor(file.path)
              .currentSession
              .getResolvedUnit(file.path);
          expect(result, isA<ResolvedUnitResult>(), reason: file.path);
          final visitor = _ButtonPressCoverage();
          (result as ResolvedUnitResult).unit.accept(visitor);
          expect(
            visitor.missing,
            isEmpty,
            reason:
                '${file.path}: STUDIO_BUTTON_PRESS requires the shared wrapper',
          );
        }
      } finally {
        await contexts.dispose();
        fixtureDirectory.deleteSync(recursive: true);
      }
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'all app selection controls suppress automatic ticks',
    () async {
      final root = Directory.current.absolute.path;
      final directory = Directory('$root/build/selection-ticks')
        ..createSync(recursive: true);
      final fixtureDirectory = directory.createTempSync('case-');
      final fixture = File('${fixtureDirectory.path}/fixture.dart')
        ..writeAsStringSync('''
import 'package:flutter/material.dart' as m;
typedef AliasChip = m.ChoiceChip;
class ChoiceChip {}
void examples() {
  AliasChip(label: const m.Text('ordered'), selected: true, showCheckmark: false);
  m.FilterChip(showCheckmark: false, label: const m.Text('filter'), selected: true, onSelected: (_) {});
  m.SegmentedButton<int>(segments: const [m.ButtonSegment(value: 1, label: m.Text('one'))], selected: const {1}, showSelectedIcon: false);
  AliasChip(label: const m.Text('missing'), selected: true);
  m.ChoiceChip(label: const m.Text('comment'), selected: true /* showCheckmark: false, */);
  m.SegmentedButton<int>(segments: const [m.ButtonSegment(value: 1, label: m.Text('one'))], selected: const {1}, showSelectedIcon: true);
  ChoiceChip();
}
''');
      final contexts = AnalysisContextCollection(
        includedPaths: ['$root/lib', fixture.path],
        sdkPath: dartSdkPath(root),
      );
      try {
        final proof = await contexts
            .contextFor(fixture.path)
            .currentSession
            .getResolvedUnit(fixture.path);
        expect(proof, isA<ResolvedUnitResult>());
        final visitor = _SelectionTickCoverage();
        (proof as ResolvedUnitResult).unit.accept(visitor);
        expect(
          visitor.missing,
          [
            'ChoiceChip@showCheckmark',
            'ChoiceChip@showCheckmark',
            'SegmentedButton@showSelectedIcon',
          ],
          reason:
              'Resolve aliases, ignore unrelated names/comments, and allow any named-argument order.',
        );
        for (final file in Directory(
          '$root/lib',
        ).listSync(recursive: true).whereType<File>()) {
          if (!file.path.endsWith('.dart')) continue;
          final result = await contexts
              .contextFor(file.path)
              .currentSession
              .getResolvedUnit(file.path);
          expect(result, isA<ResolvedUnitResult>(), reason: file.path);
          final coverage = _SelectionTickCoverage();
          (result as ResolvedUnitResult).unit.accept(coverage);
          expect(coverage.missing, isEmpty, reason: file.path);
        }
      } finally {
        await contexts.dispose();
        fixtureDirectory.deleteSync(recursive: true);
      }
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  for (final brightness in Brightness.values) {
    testWidgets(
      'long selected rows wrap at 320 dp and 200 percent in $brightness',
      (tester) async {
        tester.view.physicalSize = const Size(320, 640);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(
          MaterialApp(
            theme: wingTheme(brightness),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(2)),
              child: child!,
            ),
            home: Scaffold(
              body: SingleChildScrollView(
                child: RadioGroup<String>(
                  groupValue: 'chosen',
                  onChanged: (_) {},
                  child: Column(
                    children: [
                      const StudioRadioTile(
                        value: 'chosen',
                        enabled: false,
                        title: Text(
                          'A long profile or model name that wraps over several lines',
                        ),
                        subtitle: Text(
                          'The confirmed selection stays visible while saving.',
                        ),
                      ),
                      StudioSelectionTile(
                        value: true,
                        onChanged: (_) {},
                        title: const Text(
                          'Another long choice that wraps over several lines',
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        for (final tile in [
          find.byType(StudioRadioTile<String>),
          find.byType(StudioSelectionTile),
        ]) {
          expect(tester.getSize(tile).height, greaterThanOrEqualTo(48));
          final surfaces = tester.widgetList<Material>(
            find.descendant(of: tile, matching: find.byType(Material)),
          );
          expect(
            surfaces.first.color,
            wingTheme(brightness).colorScheme.primaryContainer,
          );
        }
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'Markdown task markers preserve completion state in $brightness',
      (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            theme: wingTheme(brightness),
            home: const Scaffold(
              body: MarkdownMessageContent(
                data: '- [x] Finished\n- [ ] Pending',
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.settleMarkdown();
        expect(
          tester
              .widgetList<StudioTaskMarker>(find.byType(StudioTaskMarker))
              .map((marker) => marker.completed),
          [true, false],
        );
      },
    );

    testWidgets(
      'background selection preserves chips, row semantics and keys in $brightness',
      (tester) async {
        tester.view.physicalSize = const Size(320, 1000);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final semantics = tester.ensureSemantics();
        try {
          var selected = 'Alpha';
          var multiple = false;
          await tester.pumpWidget(
            MaterialApp(
              theme: wingTheme(brightness),
              home: StatefulBuilder(
                builder: (context, setState) => Scaffold(
                  body: SingleChildScrollView(
                    child: Column(
                      children: [
                        ChoiceChip(
                          label: const Text('Accent'),
                          avatar: const Icon(Icons.circle),
                          selected: true,
                          onSelected: (_) {},
                        ),
                        FilterChip(
                          label: const Text('Filter'),
                          selected: true,
                          onSelected: (_) {},
                        ),
                        InputChip(
                          label: const Text('Input'),
                          selected: true,
                          onSelected: (_) {},
                        ),
                        RadioGroup<String>(
                          groupValue: selected,
                          onChanged: (value) =>
                              setState(() => selected = value!),
                          child: const Column(
                            children: [
                              StudioRadioTile(
                                value: 'Alpha',
                                title: Text('Alpha'),
                                key: Key('alpha'),
                              ),
                              StudioRadioTile(
                                value: 'Beta',
                                title: Text('Beta'),
                                key: Key('beta'),
                              ),
                              StudioRadioTile(
                                value: 'Disabled',
                                title: Text('Disabled'),
                                enabled: false,
                              ),
                            ],
                          ),
                        ),
                        StudioSelectionTile(
                          key: const Key('multiple'),
                          value: multiple,
                          title: const Text('Multiple'),
                          onChanged: (value) =>
                              setState(() => multiple = value),
                        ),
                        StudioSelectionTile(
                          value: true,
                          title: const Text('Disabled selected'),
                          onChanged: null,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          final chips = tester.widgetList<RawChip>(find.byType(RawChip));
          expect(chips, hasLength(3));
          for (final chip in chips) {
            expect(
              chip.showCheckmark ??
                  wingTheme(brightness).chipTheme.showCheckmark,
              isFalse,
            );
            expect(chip.selected, isTrue);
          }
          expect(find.byIcon(Icons.circle), findsOneWidget);
          expect(
            tester.getSemantics(find.byKey(const Key('alpha'))),
            matchesSemantics(
              label: 'Alpha',
              hasCheckedState: true,
              isChecked: true,
              hasSelectedState: true,
              isSelected: true,
              isInMutuallyExclusiveGroup: true,
              hasEnabledState: true,
              isEnabled: true,
              isFocusable: true,
              hasTapAction: true,
              hasFocusAction: true,
            ),
          );
          final alphaRadio = tester.widget<RawRadio<String>>(
            find.descendant(
              of: find.byKey(const Key('alpha')),
              matching: find.byType(RawRadio<String>),
            ),
          );
          alphaRadio.focusNode.requestFocus();
          await tester.pump();
          await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
          await tester.pumpAndSettle();
          expect(selected, 'Beta');
          await tester.tap(find.text('Disabled'));
          expect(selected, 'Beta');
          await tester.tap(find.byKey(const Key('multiple')));
          await tester.pumpAndSettle();
          expect(multiple, isTrue);
          await tester.sendKeyEvent(LogicalKeyboardKey.tab);
          await tester.pump();
          await tester.sendKeyEvent(LogicalKeyboardKey.space);
          await tester.pumpAndSettle();
          expect(multiple, isFalse);
          expect(tester.takeException(), isNull);
        } finally {
          semantics.dispose();
        }
      },
    );

    testWidgets(
      'dropdown highlights selected option without an icon in $brightness',
      (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            theme: wingTheme(brightness),
            home: Scaffold(
              body: StudioSelect<String>(
                label: 'Provider',
                value: 'one',
                options: const [
                  (value: 'one', label: 'One'),
                  (value: 'two', label: 'Two'),
                ],
                onChanged: (_) {},
              ),
            ),
          ),
        );
        await tester.tap(find.byType(DropdownMenu<String>));
        await tester.pumpAndSettle();
        final entry = tester
            .widget<DropdownMenu<String>>(find.byType(DropdownMenu<String>))
            .dropdownMenuEntries
            .first;
        expect(entry.trailingIcon, isNull);
        expect(
          entry.style!.backgroundColor!.resolve({}),
          wingTheme(brightness).colorScheme.primaryContainer,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }
}
