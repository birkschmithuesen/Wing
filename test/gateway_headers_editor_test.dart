import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/models/connection.dart';
import 'package:wing/core/widgets/gateway_headers_editor.dart';

void main() {
  test('shared validator accepts a custom access header', () {
    expect(
      validateGatewayHeaders({'CF-Access-Client-Id': 'value'}),
      isNotEmpty,
    );
  });
  for (final (reason, headers) in <(String, Map<String, String>)>[
    ('managed header', {'Host': 'value'}),
    ('case-insensitive duplicate', {'X-Test': 'one', 'x-test': 'two'}),
    ('line break in value', {'X-Test': 'bad\r\nvalue'}),
    ('invalid name', {'Bad Header': 'value'}),
    ('blank value', {'X-Blank': '   '}),
  ]) {
    test('shared validator rejects $reason', () {
      expect(() => validateGatewayHeaders(headers), throwsFormatException);
    });
  }

  test(
    'header edit retains hidden secrets without exposing or normalizing bytes',
    () {
      final rows = <GatewayHeaderDraft>[
        const GatewayHeaderDraft(
          savedName: 'X-Access',
          name: ' x-access ',
          value: '',
        ),
      ];
      final edit = GatewayHeaderEdit(rows);
      rows.clear();
      expect(edit.update, {'x-access': null});
      expect(edit.resolve({'X-Access': ' exact secret '}), {
        'X-Access': ' exact secret ',
      });
      expect(edit.nameError(0), isNull);
      expect(edit.valueError(0), isNull);
      expect(() => edit.rows.clear(), throwsUnsupportedError);
      expect(() => edit.update!.clear(), throwsUnsupportedError);
    },
  );

  testWidgets('emits saved keep, replacement and removal', (tester) async {
    final values = <Map<String, String?>>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: GatewayHeadersEditor(
            savedNames: const {'CF-Access-Client-Id'},
            onChanged: (edit) => values.add(edit.update!),
          ),
        ),
      ),
    );

    expect(find.text('Keep saved value'), findsOneWidget);
    await tester.enterText(find.byType(TextFormField).at(1), 'replacement');
    expect(values.last, {'CF-Access-Client-Id': 'replacement'});
    await tester.tap(find.byTooltip('Remove header'));
    expect(values.last, isEmpty);
  });

  for (final duplicate in [false, true]) {
    testWidgets(
      duplicate
          ? 'rejects case-insensitive duplicate header names'
          : 'renamed saved header requires a replacement value',
      (tester) async {
        final values = <Map<String, String?>>[];
        final formKey = GlobalKey<FormState>();
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Form(
                key: formKey,
                child: GatewayHeadersEditor(
                  savedNames: const {'X-Saved'},
                  onChanged: (edit) => values.add(edit.update!),
                ),
              ),
            ),
          ),
        );
        await tester.enterText(find.byType(TextFormField).first, 'X-Renamed');
        if (duplicate) {
          await tester.enterText(find.byType(TextFormField).at(1), 'secret');
          await tester.tap(find.byTooltip('Add header'));
          await tester.pump();
          await tester.enterText(find.byType(TextFormField).at(2), 'x-renamed');
          await tester.enterText(find.byType(TextFormField).at(3), 'another');
        }
        expect(formKey.currentState!.validate(), isFalse);
        await tester.pump();
        if (duplicate) {
          expect(find.text('Header names must be unique.'), findsNWidgets(2));
          expect(values.last, {'X-Renamed': 'secret'});
        } else {
          expect(find.text('Value is required'), findsOneWidget);
          expect(values, isEmpty);
        }
      },
    );
  }

  testWidgets('disabled and owner changes preserve safe controller ownership', (
    tester,
  ) async {
    final values = <Map<String, String?>>[];
    Widget editor(Set<String> names, {required bool enabled}) => MaterialApp(
      home: Scaffold(
        body: GatewayHeadersEditor(
          savedNames: names,
          enabled: enabled,
          onChanged: (edit) => values.add(edit.update!),
        ),
      ),
    );

    await tester.pumpWidget(editor(const {'X-Old'}, enabled: false));
    await tester.tap(find.byTooltip('Remove header'));
    expect(find.byType(TextFormField), findsNWidgets(2));
    expect(values, isEmpty);

    await tester.pumpWidget(editor(const {'X-New'}, enabled: true));
    await tester.pump();
    expect(find.text('X-New'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('validates a new value at 320px and 200 percent text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final values = <Map<String, String?>>[];
    final formKey = GlobalKey<FormState>();
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(2)),
          child: child!,
        ),
        home: Scaffold(
          body: SingleChildScrollView(
            child: Form(
              key: formKey,
              child: GatewayHeadersEditor(
                savedNames: const {},
                onChanged: (edit) => values.add(edit.update!),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byTooltip('Add header'));
    await tester.pump();
    await tester.enterText(find.byType(TextFormField).first, 'X-Test');
    expect(formKey.currentState!.validate(), isFalse);
    await tester.enterText(find.byType(TextFormField).last, '   ');
    expect(formKey.currentState!.validate(), isFalse);
    expect(values, isEmpty);
    expect(tester.takeException(), isNull);
  });
}
