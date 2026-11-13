import 'selection_viewport.dart';
import 'studio_form_actions.dart';
import 'studio_selection_tile.dart';
import 'studio_error.dart';
import 'package:flutter/material.dart';
import '../theme/wing_theme.dart';

import '../models/config_backup_operation.dart';

/// Offers a passphrase to protect an export, requiring confirmation so a
/// typo cannot lock the user out of their own backup.
class ExportPassphraseSheet extends StatefulWidget {
  const ExportPassphraseSheet({super.key});

  @override
  State<ExportPassphraseSheet> createState() => _ExportPassphraseSheetState();
}

class _ExportPassphraseSheetState extends State<ExportPassphraseSheet> {
  final TextEditingController _passphrase = TextEditingController();
  final TextEditingController _confirm = TextEditingController();
  String? _error;
  bool _obscure = true;

  @override
  void dispose() {
    _passphrase.dispose();
    _confirm.dispose();
    super.dispose();
  }

  void _submit() {
    try {
      final choice = BackupExportIntent(
        passphrase: _passphrase.text,
        confirmation: _confirm.text,
      );
      Navigator.of(context).pop(choice);
    } on BackupChoiceException catch (error) {
      setState(() => _error = error.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    return StudioFormSheet(
      actions: StudioFormActions(
        onCancel: () => Navigator.pop(context),
        onConfirm: _submit,
        confirmKey: const Key('export_confirm_button'),
        confirmLabel: 'Export configuration',
        confirmIcon: Icons.upload_file,
      ),
      children: [
        Text(
          'Back up configuration',
          style: Theme.of(context).textTheme.titleLarge,
        ),
        const SizedBox(height: 8),
        Text(
          'Add a passphrase to encrypt the backup, or leave it blank. '
          'Without a passphrase, anyone with the file can read your '
          'API keys and dashboard password.',
          style: TextStyle(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 16),
        viewportSelection(
          TextField(
            key: const Key('export_passphrase_field'),
            controller: _passphrase,
            obscureText: _obscure,
            autofillHints: const [AutofillHints.newPassword],
            autofocus: true,
            decoration: InputDecoration(
              labelText: 'Passphrase (optional)',
              border: const OutlineInputBorder(
                borderRadius: WingRadius.control,
              ),
              suffixIcon: StudioButtonPress(
                child: IconButton(
                  icon: Icon(
                    _obscure ? Icons.visibility : Icons.visibility_off,
                  ),
                  onPressed: () => setState(() => _obscure = !_obscure),
                  tooltip: _obscure ? 'Show passphrase' : 'Hide passphrase',
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 12),
        viewportSelection(
          TextField(
            key: const Key('export_passphrase_confirm_field'),
            controller: _confirm,
            obscureText: _obscure,
            autofillHints: const [AutofillHints.newPassword],
            decoration: const InputDecoration(
              labelText: 'Confirm passphrase',
              border: OutlineInputBorder(borderRadius: WingRadius.control),
            ),
            onSubmitted: (_) => _submit(),
          ),
        ),
        if (_error != null) ...[
          const SizedBox(height: 12),
          StudioError(_error!),
        ],
        const SizedBox(height: 20),
      ],
    );
  }
}

/// Asks for the passphrase of a backup file and how it should be applied.
class ImportOptionsSheet extends StatefulWidget {
  const ImportOptionsSheet({super.key});

  @override
  State<ImportOptionsSheet> createState() => _ImportOptionsSheetState();
}

class _ImportOptionsSheetState extends State<ImportOptionsSheet> {
  final TextEditingController _passphrase = TextEditingController();
  ConfigImportMode _mode = ConfigImportMode.merge;
  bool _obscure = true;

  @override
  void dispose() {
    _passphrase.dispose();
    super.dispose();
  }

  void _submit() {
    Navigator.of(
      context,
    ).pop(BackupImportIntent(passphrase: _passphrase.text, mode: _mode));
  }

  @override
  Widget build(BuildContext context) {
    return StudioFormSheet(
      actions: StudioFormActions(
        onCancel: () => Navigator.pop(context),
        onConfirm: _submit,
        confirmKey: const Key('import_confirm_button'),
        confirmLabel: 'Restore configuration',
        confirmIcon: Icons.restore,
      ),
      children: [
        Text(
          'Restore configuration',
          style: Theme.of(context).textTheme.titleLarge,
        ),
        const SizedBox(height: 16),
        viewportSelection(
          TextField(
            key: const Key('import_passphrase_field'),
            controller: _passphrase,
            obscureText: _obscure,
            autofillHints: const [AutofillHints.password],
            autofocus: true,
            decoration: InputDecoration(
              labelText: 'Passphrase (if encrypted)',
              border: const OutlineInputBorder(
                borderRadius: WingRadius.control,
              ),
              suffixIcon: StudioButtonPress(
                child: IconButton(
                  icon: Icon(
                    _obscure ? Icons.visibility : Icons.visibility_off,
                  ),
                  onPressed: () => setState(() => _obscure = !_obscure),
                  tooltip: _obscure ? 'Show passphrase' : 'Hide passphrase',
                ),
              ),
            ),
            onSubmitted: (_) => _submit(),
          ),
        ),
        const SizedBox(height: 16),
        RadioGroup<ConfigImportMode>(
          groupValue: _mode,
          onChanged: (value) => setState(() => _mode = value!),
          child: const Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              StudioRadioTile<ConfigImportMode>(
                minTileHeight: 48,
                minVerticalPadding: 8,
                key: Key('import_mode_merge'),
                value: ConfigImportMode.merge,
                title: Text('Merge'),
                subtitle: Text(
                  'Add and update connections from the backup, keep the '
                  'rest.',
                ),
                contentPadding: EdgeInsets.zero,
              ),
              StudioRadioTile<ConfigImportMode>(
                minTileHeight: 48,
                minVerticalPadding: 8,
                key: Key('import_mode_replace'),
                value: ConfigImportMode.replace,
                title: Text('Replace'),
                subtitle: Text(
                  'Delete connections that are not in the backup.',
                ),
                contentPadding: EdgeInsets.zero,
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),
      ],
    );
  }
}
