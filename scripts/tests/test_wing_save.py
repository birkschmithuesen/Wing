"""Exercise workspace saves against real local repositories and bare remotes."""
import contextlib
import importlib.util
import io
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest import mock


SCRIPT = Path(__file__).resolve().parents[1] / 'wing_save.py'
spec = importlib.util.spec_from_file_location('wing_save', SCRIPT)
workflow = importlib.util.module_from_spec(spec)
spec.loader.exec_module(workflow)


class WorkspaceSaveTest(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory(prefix='wing-save-')
        self.addCleanup(directory.cleanup)
        self.base = Path(directory.name)
        self.app = self.base / 'app'
        self.internal = self.app / 'internal'
        self.app_remote = self.base / 'github.git'
        self.internal_remote = self.base / 'gitea.git'
        for remote in (self.app_remote, self.internal_remote):
            self.run_git(self.base, 'init', '--bare', '-q', str(remote))
        self.initialize(self.app, self.app_remote)
        (self.app / '.gitignore').write_text('/internal/\n')
        (self.app / 'app.txt').write_text('initial app\n')
        self.commit(self.app, 'Initial app')
        self.initialize(self.internal, self.internal_remote)
        (self.internal / 'notes.md').write_text('initial private notes\n')
        self.commit(self.internal, 'Initial notes')
        self.run_git(self.app, 'config', '--local', 'wing.appRemote', str(self.app_remote))
        self.run_git(self.app, 'config', '--local', 'wing.internalRemote', str(self.internal_remote))
        self.initial_app = self.head(self.app)
        self.initial_internal = self.head(self.internal)

    def run_git(self, root, *args):
        return subprocess.run(['git', '-C', str(root), *args], check=True,
                              capture_output=True, text=True).stdout.strip()

    def initialize(self, root, remote):
        self.run_git(self.base, 'init', '-q', '-b', 'main', str(root))
        self.run_git(root, 'config', 'user.name', 'Save test')
        self.run_git(root, 'config', 'user.email', 'save@example.invalid')
        self.run_git(root, 'remote', 'add', 'origin', str(remote))

    def commit(self, root, message):
        self.run_git(root, 'add', '-A')
        self.run_git(root, 'commit', '-qm', message)
        self.run_git(root, 'push', '-q', 'origin', 'HEAD:refs/heads/main')

    def head(self, root):
        return self.run_git(root, 'rev-parse', 'HEAD')

    def remote_head(self, root):
        return self.run_git(root, 'rev-parse', 'refs/heads/main')

    def save(self, message='Save work', **kwargs):
        with contextlib.redirect_stdout(io.StringIO()) as stream:
            workflow.save(self.app, message, **kwargs)
        return stream.getvalue()

    def edits(self):
        (self.app / 'app.txt').write_text('staged app\n')
        self.run_git(self.app, 'add', 'app.txt')
        (self.app / 'app.txt').write_text('later unstaged app\n')
        (self.internal / 'notes.md').write_text('private research\n')

    def reject_push(self, remote):
        hook = remote / 'hooks/pre-receive'
        hook.write_text('#!/bin/sh\nexit 1\n')
        hook.chmod(0o755)
        return hook

    def test_saves_both_without_publishing_internal_or_unstaged_app(self):
        self.edits()
        self.save()
        self.assertEqual(self.head(self.app), self.remote_head(self.app_remote))
        self.assertEqual(self.head(self.internal), self.remote_head(self.internal_remote))
        self.assertEqual('staged app', self.run_git(self.app_remote, 'show', 'main:app.txt'))
        self.assertEqual('later unstaged app\n', (self.app / 'app.txt').read_text())
        self.assertNotIn('internal', self.run_git(self.app_remote, 'ls-tree', '-r', '--name-only', 'main'))
        self.assertEqual('private research', self.run_git(self.internal_remote, 'show', 'main:notes.md'))
        self.assertIn(f'Wing-Commit: {self.head(self.app)}',
                      self.run_git(self.internal, 'log', '-1', '--format=%B'))

    def test_internal_only_and_unchanged_retries_create_no_app_commit(self):
        (self.internal / 'notes.md').write_text('internal-only change\n')
        self.save()
        saved = self.head(self.internal)
        self.assertEqual(self.initial_app, self.head(self.app))
        self.save()
        self.assertEqual(saved, self.head(self.internal))
        self.assertEqual(saved, self.remote_head(self.internal_remote))

    def test_private_failure_stops_public_push_and_retry_preserves_later_edits(self):
        self.edits()
        hook = self.reject_push(self.internal_remote)
        with self.assertRaises(workflow.SaveError):
            self.save()
        app_sha, internal_sha = self.head(self.app), self.head(self.internal)
        self.assertNotEqual(self.initial_app, app_sha)
        self.assertEqual(self.initial_app, self.remote_head(self.app_remote))
        self.assertEqual(self.initial_internal, self.remote_head(self.internal_remote))
        (self.internal / 'notes.md').write_text('later notes\n')
        hook.unlink()
        self.save(None, push_only=True)
        self.assertEqual(app_sha, self.remote_head(self.app_remote))
        self.assertEqual(internal_sha, self.remote_head(self.internal_remote))
        self.assertEqual('later notes\n', (self.internal / 'notes.md').read_text())
        self.assertIn('notes.md', self.run_git(self.internal, 'diff', '--name-only'))

    def test_public_push_failure_leaves_private_saved_and_both_retryable(self):
        self.edits()
        hook = self.reject_push(self.app_remote)
        with self.assertRaises(workflow.SaveError):
            self.save()
        self.assertEqual(self.head(self.internal), self.remote_head(self.internal_remote))
        self.assertEqual(self.initial_app, self.remote_head(self.app_remote))
        saved_app, saved_internal = self.head(self.app), self.head(self.internal)
        hook.unlink()
        self.save(None, push_only=True)
        self.assertEqual(saved_app, self.remote_head(self.app_remote))
        self.assertEqual(saved_internal, self.head(self.internal))

    def test_existing_app_hook_failure_prevents_private_commit(self):
        self.edits()
        hook = self.app / '.git/hooks/pre-commit'
        hook.write_text('#!/bin/sh\nexit 1\n')
        hook.chmod(0o755)
        with self.assertRaises(workflow.SaveError):
            self.save()
        self.assertEqual(self.initial_app, self.head(self.app))
        self.assertEqual(self.initial_internal, self.head(self.internal))
        self.assertTrue(workflow.changed(self.app))

    def test_hook_cannot_publish_private_content_staged_after_preflight(self):
        self.edits()
        (self.internal / 'leak.md').write_text('private\n')
        blob = self.run_git(self.app, 'hash-object', '-w', 'internal/leak.md')
        hook = self.app / '.git/hooks/pre-commit'
        hook.write_text('#!/bin/sh\n'
                        f'git update-index --add --cacheinfo 100644 {blob} internal/leak.md\n')
        hook.chmod(0o755)
        with self.assertRaises(workflow.SaveError):
            self.save()
        self.assertEqual(self.initial_app, self.remote_head(self.app_remote))
        self.assertEqual(self.initial_internal, self.head(self.internal))

    def test_hook_cannot_redirect_private_push(self):
        self.edits()
        hook = self.app / '.git/hooks/pre-commit'
        hook.write_text('#!/bin/sh\ngit -C internal remote set-url origin '
                        + str(self.app_remote) + '\n')
        hook.chmod(0o755)
        self.save()
        self.assertEqual(self.head(self.internal), self.remote_head(self.internal_remote))
        self.assertEqual(self.head(self.app), self.remote_head(self.app_remote))
        self.assertNotIn('notes.md', self.run_git(self.app_remote, 'ls-tree', '-r', '--name-only', 'main'))

    def test_rejects_tracked_internal_content_before_committing_either_repo(self):
        (self.internal / 'leak.md').write_text('private\n')
        blob = self.run_git(self.app, 'hash-object', '-w', 'internal/leak.md')
        self.run_git(self.app, 'update-index', '--add', '--cacheinfo',
                     '100644', blob, 'internal/leak.md')
        before = self.run_git(self.app, 'diff', '--cached', '--name-only')
        self.assertIn('internal/leak.md', before)
        with self.assertRaisesRegex(workflow.SaveError, 'tracks internal'):
            self.save()
        self.assertEqual(before, self.run_git(self.app, 'diff', '--cached', '--name-only'))
        self.assertEqual(self.initial_app, self.head(self.app))
        self.assertEqual(self.initial_internal, self.head(self.internal))

    def test_rejects_private_commit_even_when_deleted_from_index_or_later_commit(self):
        (self.internal / 'leak.md').write_text('private\n')
        blob = self.run_git(self.app, 'hash-object', '-w', 'internal/leak.md')
        self.run_git(self.app, 'update-index', '--add', '--cacheinfo',
                     '100644', blob, 'internal/leak.md')
        self.run_git(self.app, 'commit', '-qm', 'Accidental private commit')
        self.run_git(self.app, 'update-index', '--force-remove', 'internal/leak.md')
        with self.assertRaisesRegex(workflow.SaveError, 'commit history contains internal'):
            self.save(None, push_only=True)
        self.run_git(self.app, 'commit', '-qm', 'Remove private content')
        with self.assertRaisesRegex(workflow.SaveError, 'commit history contains internal'):
            self.save(None, push_only=True)
        self.assertEqual(self.initial_app, self.remote_head(self.app_remote))

    def test_requires_ignore_rule_in_app_index_despite_local_exclusion(self):
        (self.app / '.gitignore').write_text('')
        self.run_git(self.app, 'add', '.gitignore')
        (self.app / '.git/info/exclude').write_text('/internal/\n')
        with self.assertRaisesRegex(workflow.SaveError, 'tracked app .gitignore'):
            self.save()
        self.assertEqual(self.initial_app, self.head(self.app))
        self.assertEqual(self.initial_internal, self.head(self.internal))

    def test_push_uses_captured_app_commit_when_another_tool_commits(self):
        self.edits()
        original_git = workflow.git
        captured = []

        def interleave(root, *args, **kwargs):
            result = original_git(root, *args, **kwargs)
            if root == self.internal and 'push' in args:
                captured.append(self.head(self.app))
                (self.app / 'other-task.txt').write_text('concurrent work\n')
                self.run_git(self.app, 'add', 'other-task.txt')
                self.run_git(self.app, 'commit', '-qm', 'Another task')
            return result

        with mock.patch.object(workflow, 'git', side_effect=interleave):
            self.save()
        self.assertEqual(captured[0], self.remote_head(self.app_remote))
        self.assertNotEqual(captured[0], self.head(self.app))
        self.assertIn(f'Wing-Commit: {captured[0]}',
                      self.run_git(self.internal, 'log', '-1', '--format=%B'))

    def test_preflight_rejects_wrong_remote_missing_nested_repo_and_git_operation(self):
        self.edits()
        self.run_git(self.internal, 'remote', 'set-url', 'origin', str(self.app_remote))
        with self.assertRaisesRegex(workflow.SaveError, 'origin differs'):
            self.save()
        self.run_git(self.internal, 'remote', 'set-url', 'origin', str(self.internal_remote))
        private_git = self.internal / '.git'
        private_git.rename(self.base / 'private-metadata')
        with self.assertRaisesRegex(workflow.SaveError, 'independent Git checkout'):
            self.save()
        (self.base / 'private-metadata').rename(private_git)
        (private_git / 'MERGE_HEAD').write_text(self.initial_internal)
        with self.assertRaisesRegex(workflow.SaveError, 'active Git operation'):
            self.save()
        self.assertEqual(self.initial_app, self.head(self.app))
        self.assertTrue(workflow.changed(self.app))

    def test_commit_only_and_foreign_git_context(self):
        self.edits()
        foreign_index = self.base / 'foreign-index'
        with mock.patch.dict(os.environ, {'GIT_INDEX_FILE': str(foreign_index),
                                          'GIT_DIR': str(self.internal / '.git')}):
            self.save(commit_only=True)
        self.assertFalse(foreign_index.exists())
        self.assertNotEqual(self.initial_app, self.head(self.app))
        self.assertNotEqual(self.initial_internal, self.head(self.internal))
        self.assertEqual(self.initial_app, self.remote_head(self.app_remote))
        self.assertEqual(self.initial_internal, self.remote_head(self.internal_remote))

    def test_rejects_simultaneous_save(self):
        with workflow.save_lock(self.app):
            with self.assertRaisesRegex(workflow.SaveError, 'Another Wing save'):
                self.save()


if __name__ == '__main__':
    unittest.main()
