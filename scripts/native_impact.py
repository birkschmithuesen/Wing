"""Select native families from their executable inputs, conservatively.

The nightly catalog lives here. Dart imports connect production and shared
scenario changes to their Android entrypoints. Unmapped executable inputs run
the whole catalog; an incomplete graph must never turn into a green skip.
"""
import ast
import posixpath
from pathlib import Path
import re
import subprocess


FAMILY_INPUTS = {
    'journeys': ('scripts/test_journeys.py',),
    'notification-actions': ('integration_test/notification_revamp_device.dart', 'tools/qa/check_notification_revamp.py'),
    'notification-restore': ('integration_test/notification_revamp_device.dart', 'scripts/test_native_notification_restore.py'),
    'notification-counts': ('integration_test/notification_revamp_device.dart', 'scripts/test_native_notification_counts.py'),
    'notification-cold': ('integration_test/notification_cold_input_device.dart', 'scripts/test_native_cold_notification.py'),
    'background': ('integration_test/background_monitoring_device.dart', 'tools/qa/check_background_monitoring.py'),
    'health-normal': ('integration_test/health_alerts_native_test.dart',),
    'health-large': ('integration_test/health_alerts_native_test.dart',),
    'health-retention': ('integration_test/health_alerts_native_test.dart',),
    'backup': ('scripts/test_native_config_backup.py', 'integration_test/fixtures/external_share'),
    'bots': ('scripts/test_native_bots.py',),
    'file-transfer': ('scripts/test_native_file_transfer.py', 'integration_test/fixtures/external_share'),
    'voice': ('scripts/test_native_voice.py', 'integration_test/fixtures/external_share'),
    **{name: ('scripts/test_native_recents.py', 'integration_test/fixtures/recents_touch')
       for name in ('recents', 'recents-code', 'recents-events', 'recents-momentum')},
    'platform-plugins': ('integration_test/dependency_plugins_native_test.dart',),
    'scheduled-tasks': ('integration_test/scheduled_tasks_native_test.dart',),
    'administration': ('integration_test/administration_native_test.dart',),
    'queue-editing': ('integration_test/queued_message_edit_test.dart',),
    'health-entry': ('integration_test/administration_health_entry_test.dart',),
    'transcript-expansion': ('integration_test/profile_expansion_scroll_test.dart',),
    'slash': ('integration_test/slash_completion_native_test.dart',),
    'html': ('integration_test/large_html_native_preview.dart', 'scripts/check-large-html-native.mjs'),
    'stock-hermes': ('scripts/test_vanilla_hermes.py',),
    'external-share': ('integration_test/share_intake_device.dart', 'tools/qa/check_external_share.py', 'integration_test/fixtures/external_share'),
    'clipboard': ('integration_test/clipboard_device_test.dart', 'tools/qa/check_external_share.py', 'integration_test/fixtures/external_share'),
}
FAMILIES = tuple(FAMILY_INPUTS)


def dependencies(root: Path, seeds, *, named_inputs=True):
    seen, pending = set(), list(seeds)
    while pending:
        name = pending.pop()
        if name in seen:
            continue
        seen.add(name)
        path = root / name
        if path.is_dir():
            pending.extend(str(p.relative_to(root)) for p in path.rglob('*') if p.is_file())
            continue
        if not path.is_file():
            continue  # Deleted inputs remain in the graph.
        if path.suffix not in {'.dart', '.py', '.mjs', '.js'}:
            continue
        source = path.read_text()
        if path.suffix == '.dart':
            for directive in re.findall(r'\b(?:import|export|part)\s+[^;]+;', source):
                for uri in re.findall(r"['\"]([^'\"]+)['\"]", directive):
                    if uri.startswith('package:wing/'):
                        pending.append('lib/' + uri.removeprefix('package:wing/'))
                    elif ':' not in uri:
                        pending.append(posixpath.normpath(str(Path(name).parent / uri)))
        elif path.suffix == '.py':
            tree = ast.parse(source)
            for node in ast.walk(tree):
                modules = []
                if isinstance(node, ast.Import):
                    modules = [entry.name for entry in node.names]
                elif isinstance(node, ast.ImportFrom) and node.module:
                    modules = [node.module, *(node.module + '.' + entry.name for entry in node.names)]
                for module in modules:
                    candidate = module.replace('.', '/') + '.py'
                    if (root / candidate).is_file():
                        pending.append(candidate)
        # Drivers name their Flutter suites and helper programs as literals.
        if named_inputs:
            pending.extend(re.findall(
                r"['\"]((?:integration_test|test|scripts|tools)/[^'\"\s]+\.(?:dart|py|mjs|js))['\"]", source))
    return seen


def select(root: Path, paths):
    graphs = {family: dependencies(root, seeds) for family, seeds in FAMILY_INPUTS.items()}
    shared = dependencies(root, ['scripts/test_nightly_native.py'], named_inputs=False)
    reasons = {family: [] for family in FAMILIES}
    for name in sorted(set(paths)):
        if name.startswith(('docs/', 'internal/')) or (
                name.endswith('.md') and (Path(name).parent == Path('.') or name.startswith('.agents/'))):
            continue
        infrastructure = name in shared or name.startswith(('.github/', 'android/')) or name in {
            'pubspec.yaml', 'pubspec.lock', 'scripts/test.py',
            'scripts/test_nightly_native.py', 'scripts/native_impact.py',
            'tools/qa/run_notification_gate.py', 'test/flutter_test_config.dart',
        }
        affected = ([] if infrastructure else
                    [family for family, inputs in graphs.items() if name in inputs])
        # Native/build/runner changes and new or deleted unknown code need all
        # families. Only known documentation is allowed to select no work.
        for family in affected or FAMILIES:
            reasons[family].append(name)
    return {family: paths for family, paths in reasons.items() if paths}


def changed_paths(root: Path, reference: str):
    if not reference or set(reference) == {'0'}:
        return None
    try:
        revision = subprocess.check_output(
            ['git', 'rev-parse', '--verify', '--end-of-options', reference + '^{commit}'],
            cwd=root, stderr=subprocess.DEVNULL, text=True).strip()
        changed = subprocess.check_output(
            ['git', 'diff', '--no-renames', '--name-only', '-z', revision, '--'], cwd=root)
        untracked = subprocess.check_output(
            ['git', 'ls-files', '--others', '--exclude-standard', '-z'], cwd=root)
    except (OSError, subprocess.CalledProcessError):
        return None
    return [name for name in (changed + untracked).decode().split('\0') if name]


def plan(root: Path, reference: str):
    paths = changed_paths(root, reference)
    reasons = ({family: ['Base revision unavailable: run every family'] for family in FAMILIES}
               if paths is None else select(root, paths))
    return {'families': list(reasons), 'reasons': reasons, 'changed': paths}
