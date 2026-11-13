import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/models/config_backup_operation.dart';
import 'package:wing/core/widgets/config_backup_card.dart';

Future<void> openSheet<T>(
  WidgetTester tester,
  Widget sheet,
  Completer<T?> result,
) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              result.complete(
                await showModalBottomSheet<T>(
                  context: context,
                  isScrollControlled: true,
                  builder: (_) => sheet,
                ),
              );
            },
            child: const Text('Open sheet'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Open sheet'));
  await tester.pumpAndSettle();
}

Future<void> completeExportSheet(
  WidgetTester tester, {
  required String passphrase,
  String? confirm,
}) async {
  await tester.enterText(
    find.byKey(const Key('export_passphrase_field')),
    passphrase,
  );
  await tester.enterText(
    find.byKey(const Key('export_passphrase_confirm_field')),
    confirm ?? passphrase,
  );
  await tester.tap(find.byKey(const Key('export_confirm_button')));
  await tester.pumpAndSettle();
}

void main() {
  group('export sheet', () {
    testWidgets('allows export with both passphrase fields empty', (
      tester,
    ) async {
      final result = Completer<BackupExportIntent?>();
      await openSheet(tester, const ExportPassphraseSheet(), result);
      await completeExportSheet(tester, passphrase: '');

      expect((await result.future)!.passphrase, '');
      expect(find.byKey(const Key('export_passphrase_field')), findsNothing);
    });

    testWidgets('returns the confirmed passphrase as the export choice', (
      tester,
    ) async {
      final result = Completer<BackupExportIntent?>();
      await openSheet(tester, const ExportPassphraseSheet(), result);
      await completeExportSheet(tester, passphrase: 'correct horse');

      expect((await result.future)!.passphrase, 'correct horse');
    });

    testWidgets('refuses to export when the confirmation does not match', (
      tester,
    ) async {
      final result = Completer<BackupExportIntent?>();
      await openSheet(tester, const ExportPassphraseSheet(), result);
      await completeExportSheet(
        tester,
        passphrase: 'correct horse',
        confirm: 'wrong horse',
      );

      expect(result.isCompleted, isFalse);
      expect(find.text('The two passphrases do not match.'), findsOneWidget);
    });

    testWidgets('refuses a passphrase that is too short to protect keys', (
      tester,
    ) async {
      final result = Completer<BackupExportIntent?>();
      await openSheet(tester, const ExportPassphraseSheet(), result);
      await completeExportSheet(tester, passphrase: 'short');

      expect(result.isCompleted, isFalse);
      expect(find.text('Use at least 8 characters.'), findsOneWidget);
    });

    testWidgets('cancelling the export sheet returns no choice', (
      tester,
    ) async {
      final result = Completer<BackupExportIntent?>();
      await openSheet(tester, const ExportPassphraseSheet(), result);
      await tester.enterText(
        find.byKey(const Key('export_passphrase_field')),
        'correct horse',
      );
      await tester.tap(find.byTooltip('Cancel'));
      await tester.pumpAndSettle();

      expect(await result.future, isNull);
      expect(find.byKey(const Key('export_passphrase_field')), findsNothing);
    });
  });

  group('import sheet', () {
    for (final passphrase in ['correct horse', '']) {
      testWidgets(
        passphrase.isEmpty
            ? 'allows import without a passphrase'
            : 'returns the chosen passphrase and merge mode',
        (tester) async {
          final result = Completer<BackupImportIntent?>();
          await openSheet(tester, const ImportOptionsSheet(), result);
          await tester.enterText(
            find.byKey(const Key('import_passphrase_field')),
            passphrase,
          );
          await tester.tap(find.byKey(const Key('import_confirm_button')));
          await tester.pumpAndSettle();

          final choice = (await result.future)!;
          expect(choice.passphrase, passphrase);
          expect(choice.mode, ConfigImportMode.merge);
          expect(
            find.byKey(const Key('import_passphrase_field')),
            findsNothing,
          );
        },
      );
    }

    testWidgets('returns replace mode when the user selects it', (
      tester,
    ) async {
      final result = Completer<BackupImportIntent?>();
      await openSheet(tester, const ImportOptionsSheet(), result);
      await tester.enterText(
        find.byKey(const Key('import_passphrase_field')),
        'pass',
      );
      await tester.tap(find.byKey(const Key('import_mode_replace')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('import_confirm_button')));
      await tester.pumpAndSettle();

      final choice = (await result.future)!;
      expect(choice.mode, ConfigImportMode.replace);
      expect(choice.passphrase, 'pass');
    });

    testWidgets('cancelling the import sheet returns no choice', (
      tester,
    ) async {
      final result = Completer<BackupImportIntent?>();
      await openSheet(tester, const ImportOptionsSheet(), result);
      await tester.enterText(
        find.byKey(const Key('import_passphrase_field')),
        'pass',
      );
      await tester.tap(find.byKey(const Key('import_mode_replace')));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Cancel'));
      await tester.pumpAndSettle();

      expect(await result.future, isNull);
      expect(find.byKey(const Key('import_passphrase_field')), findsNothing);
    });
  });
}
