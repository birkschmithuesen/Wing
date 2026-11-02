import 'dart:convert';

import 'package:wing/core/services/app_preferences.dart';
import 'package:wing/core/services/connection_access.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wing/core/models/hermes_profile.dart';
import 'package:wing/core/models/profile_identity_edit.dart';
import 'package:wing/core/screens/profile_workspace_screen.dart';
import 'package:wing/core/services/connection_manager.dart';
import 'package:wing/core/services/profile_gateway.dart';
import 'package:wing/core/services/profile_workspace_controller.dart';
import 'package:wing/core/services/profile_identity_edit_session.dart';
import 'package:wing/core/services/administration_repository.dart';
import 'package:wing/core/services/server_connection_status.dart';
import 'package:wing/core/screens/administration/admin_identity_page.dart';

/// Opt-in UI acceptance against the disposable android-qa-a profile.
///
/// This test creates and removes one nonce-tagged project. It also changes the
/// profile description and SOUL, verifies them through an independent gateway,
/// then restores both original values. It never submits a prompt or changes
/// backend configuration.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  WidgetController.hitTestWarningShouldBeFatal = true;
  const port = int.fromEnvironment('HERMES_TEST_PORT');

  SavedConnection connection() => SavedConnection(
    id: 'profile-admin-live-qa',
    label: 'Profile admin live QA',
    host: '127.0.0.1',
    port: port,
    dashboardPortOverride: port,
    apiKey: '',
    dashboardUsername: const String.fromEnvironment('HERMES_TEST_USERNAME'),
    dashboardPassword: const String.fromEnvironment('HERMES_TEST_PASSWORD'),
  );

  WorkspaceScope scope(String identity) => WorkspaceScope(
    connectionId: connection().id,
    connectionIdentity: identity,
    profileName: 'android-qa-a',
  );

  Future<ProfileWorkspaceController> controller(
    SharedPreferences preferences,
    AppPreferences appPreferences,
  ) async {
    final result = ProfileWorkspaceController(
      connectionIdentity: 'profile-admin-controller',
      access: ConnectionAccess(connection: connection(), dashboardOAuth: null),
      preferences: preferences,
      appPreferences: appPreferences,
    );
    addTearDown(result.dispose);
    await result.initialize();
    await result.switchProfile('android-qa-a');
    expect(result.error, isNull);
    expect(result.current?.scope.profileName, 'android-qa-a');
    return result;
  }

  Future<void> until(
    WidgetTester tester,
    bool Function() condition, {
    int seconds = 30,
    String Function()? diagnostic,
  }) async {
    final deadline = DateTime.now().add(Duration(seconds: seconds));
    while (!condition() && DateTime.now().isBefore(deadline)) {
      await tester.pump(const Duration(milliseconds: 200));
      expect(tester.takeException(), isNull);
    }
    expect(condition(), isTrue, reason: diagnostic?.call());
  }

  Future<ProfileIdentityObservation> describe(
    ProfileAdministration profile,
  ) async {
    final result = await profile.loadIdentity();
    expect(result.issues, isEmpty);
    expect(result.values.keys, containsAll(ProfileIdentityField.values));
    return result;
  }

  Future<void> configure(
    ProfileAdministration profile, {
    required String description,
    required String soul,
  }) async {
    final opening = await describe(profile);
    final result = await profile.saveIdentity(
      ProfileIdentityEditIntent(
        baseline: opening.values,
        wanted: {
          ProfileIdentityField.description: description,
          ProfileIdentityField.soul: soul,
        },
      ),
      canDispatch: () => true,
      onDispatched: (_) {},
    );
    expect(
      result.fields.keys,
      containsAll([
        ProfileIdentityField.description,
        ProfileIdentityField.soul,
      ]),
    );
    expect(
      result.fields.values.every(
        (field) =>
            field.disposition == ProfileIdentityWriteDisposition.confirmed ||
            field.disposition == ProfileIdentityWriteDisposition.converged,
      ),
      isTrue,
    );
  }

  testWidgets(
    'project create rename appearance reload and delete use the real UI',
    (tester) async {
      expect(port, greaterThan(0), reason: 'Supply HERMES_TEST_PORT');
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      final appPreferences = AppPreferences(preferences);
      addTearDown(appPreferences.dispose);
      final workspace = await controller(preferences, appPreferences);
      final verifier = ProfileGateway.forConnection(
        ConnectionAccess(connection: connection(), dashboardOAuth: null),
        scope('profile-admin-project-verifier'),
      );
      final nonce = DateTime.now().microsecondsSinceEpoch;
      final initialName = 'Android admin QA $nonce';
      final renamed = 'Android admin renamed $nonce';
      String? createdId;
      Object? cleanupFailure;
      try {
        await verifier.connect();
        final folder = await verifier.files.directory(null);
        expect(folder.path, isNotEmpty);
        await tester.pumpWidget(
          MaterialApp(home: ProfileWorkspaceScreen(controller: workspace)),
        );
        await tester.pumpAndSettle();

        await tester.tap(find.byTooltip('Chat list options'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('New project'));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('chat-menu-android-qa-a')));
        await until(
          tester,
          () => find
              .byKey(const ValueKey('project-name-field'))
              .hitTestable()
              .evaluate()
              .isNotEmpty,
        );
        await tester.enterText(
          find.byKey(const ValueKey('project-name-field')),
          initialName,
        );
        await tester.tap(find.byKey(const ValueKey('project-choose-folder')));
        await until(
          tester,
          () => find
              .byWidgetPredicate(
                (widget) =>
                    widget is IconButton &&
                    widget.tooltip == 'Use this folder' &&
                    widget.onPressed != null,
              )
              .evaluate()
              .isNotEmpty,
        );
        await tester.tap(find.byKey(const ValueKey('project-folder-continue')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('project-create-confirm')));
        await until(
          tester,
          () =>
              find
                  .byKey(const ValueKey('project-folder-continue'))
                  .evaluate()
                  .isEmpty &&
              workspace.current!.projects.any(
                (row) => row['name'] == initialName,
              ),
          diagnostic: () {
            final dialogText = find
                .descendant(
                  of: find.byType(AlertDialog),
                  matching: find.byType(Text),
                )
                .evaluate()
                .map((element) => (element.widget as Text).data)
                .whereType<String>()
                .join(' | ');
            final snackbarText = find
                .descendant(
                  of: find.byType(SnackBar),
                  matching: find.byType(Text),
                )
                .evaluate()
                .map((element) => (element.widget as Text).data)
                .whereType<String>()
                .join(' | ');
            return 'workspace=${workspace.error}; '
                'projects=${workspace.current?.projectsError}; '
                'dialog=$dialogText; snackbar=$snackbarText';
          },
        );
        await tester.pumpAndSettle();

        var rows = await verifier.projects();
        final created = rows.singleWhere((row) => row['name'] == initialName);
        createdId = created['id'] as String;
        expect(
          created['primary_path'].toString().replaceAll('\\', '/'),
          folder.path.replaceAll('\\', '/'),
        );

        Finder actions() => find.descendant(
          of: find.byKey(ValueKey('project-android-qa-a-$createdId')),
          matching: find.byTooltip('Project actions'),
        );
        await tester.tap(actions());
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const ValueKey('project-action-editProject')),
        );
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const ValueKey('project-name-field')),
          renamed,
        );
        await tester.ensureVisible(
          find.byKey(const ValueKey('project-color-9')),
        );
        await tester.tap(find.byKey(const ValueKey('project-color-9')));
        await tester.tap(find.byKey(const ValueKey('project-choose-icon')));
        await tester.pumpAndSettle();
        await tester.ensureVisible(
          find.byKey(const ValueKey('project-icon-rocket')),
        );
        await tester.tap(find.byKey(const ValueKey('project-icon-rocket')));
        await tester.tap(find.byTooltip('Use selected icon'));
        await tester.pumpAndSettle();
        await tester.ensureVisible(
          find.byKey(const ValueKey('project-edit-confirm')),
        );
        await tester.tap(find.byKey(const ValueKey('project-edit-confirm')));
        await until(
          tester,
          () =>
              find
                  .byKey(const ValueKey('project-edit-confirm'))
                  .evaluate()
                  .isEmpty &&
              workspace.current!.projects.any(
                (row) =>
                    row['id'] == createdId &&
                    row['name'] == renamed &&
                    row['color'] == 'hsl(270 68% 58%)' &&
                    row['icon'] == 'rocket',
              ),
          diagnostic: () {
            final confirm = find.byKey(const ValueKey('project-edit-confirm'));
            final projects = workspace.current!.projects
                .where((row) => row['id'] == createdId)
                .map(
                  (row) => {
                    'id': row['id'],
                    'name': row['name'],
                    'color': row['color'],
                    'icon': row['icon'],
                  },
                )
                .toList();
            final state = {
              'editorPresent': confirm.evaluate().isNotEmpty,
              'confirmHitTestable': confirm.hitTestable().evaluate().isNotEmpty,
              'workspaceError': workspace.error?.toString(),
              'projectsError': workspace.current?.projectsError?.toString(),
              'projects': projects,
            };
            return 'Project save state: ${jsonEncode(state)}';
          },
        );
        await tester.pumpAndSettle();

        rows = await verifier.projects();
        final reloaded = rows.singleWhere((row) => row['id'] == createdId);
        expect(reloaded['name'], renamed);
        expect(reloaded['color'], 'hsl(270 68% 58%)');
        expect(reloaded['icon'], 'rocket');
        expect(
          reloaded['primary_path'].toString().replaceAll('\\', '/'),
          folder.path.replaceAll('\\', '/'),
        );

        await tester.tap(actions());
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('project-action-delete')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('project-delete-confirm')));
        await until(
          tester,
          () =>
              find
                  .byKey(const ValueKey('project-delete-confirm'))
                  .evaluate()
                  .isEmpty &&
              !workspace.current!.projects.any((row) => row['id'] == createdId),
        );
        await tester.pumpAndSettle();
        expect(
          (await verifier.projects()).any((row) => row['id'] == createdId),
          false,
        );
        createdId = null;
      } finally {
        try {
          final owned = (await verifier.projects()).where(
            (row) => row['name'] == initialName || row['name'] == renamed,
          );
          for (final row in owned) {
            final id = row['id'];
            if (id is String && id.isNotEmpty) {
              await verifier.deleteProject(id, canDispatch: () => true);
            }
          }
          expect(
            (await verifier.projects()).where(
              (row) => row['name'] == initialName || row['name'] == renamed,
            ),
            isEmpty,
            reason: 'Nonce-owned projects must be removed after cleanup',
          );
        } catch (error) {
          cleanupFailure = error;
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          verifier.close();
        }
        if (cleanupFailure != null) {
          fail('Project live cleanup failed: $cleanupFailure');
        }
      }
    },
    skip: port == 0,
    timeout: const Timeout(Duration(minutes: 3)),
  );

  testWidgets(
    'profile editor saves through UI and restores original server values',
    (tester) async {
      expect(port, greaterThan(0), reason: 'Supply HERMES_TEST_PORT');
      SharedPreferences.setMockInitialValues({});
      final editorStatus = ServerConnectionStatus(connection().label);
      final verifierStatus = ServerConnectionStatus(connection().label);
      final editorServer = AdministrationRepository.forConnection(
        ConnectionAccess(connection: connection(), dashboardOAuth: null),
        'profile-admin-editor',
        connectionStatus: editorStatus,
      );
      final verifierServer = AdministrationRepository.forConnection(
        ConnectionAccess(connection: connection(), dashboardOAuth: null),
        'profile-admin-editor-verifier',
        connectionStatus: verifierStatus,
      );
      final editorProfile = editorServer.profile('android-qa-a');
      final verifierProfile = verifierServer.profile('android-qa-a');
      final nonce = DateTime.now().microsecondsSinceEpoch;
      ProfileIdentityObservation? original;
      Object? cleanupFailure;
      try {
        original = await describe(verifierProfile);
        final description = 'Android live description $nonce';
        final soul = 'Android live SOUL $nonce\nPreserve this newline.\n';
        await tester.pumpWidget(
          MaterialApp(
            home: Builder(
              builder: (context) => Scaffold(
                body: Center(
                  child: FilledButton(
                    onPressed: () => showAdminIdentityEditor(
                      context,
                      createSession: () =>
                          ProfileIdentityEditSession(editorProfile),
                    ),
                    child: const Text('Edit profile'),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Edit profile'));
        await until(
          tester,
          () => find
              .byKey(const ValueKey('profile-description-field'))
              .evaluate()
              .isNotEmpty,
        );
        await tester.enterText(
          find.byKey(const ValueKey('profile-description-field')),
          description,
        );
        await tester.enterText(
          find.byKey(const ValueKey('profile-soul-field')),
          soul,
        );
        await tester.ensureVisible(find.byTooltip('Save changes'));
        await tester.tap(find.byTooltip('Save changes'));
        await until(
          tester,
          () => find
              .byKey(const ValueKey('profile-description-field'))
              .evaluate()
              .isEmpty,
        );

        final reloaded = await describe(verifierProfile);
        expect(reloaded.values[ProfileIdentityField.description], description);
        expect(reloaded.values[ProfileIdentityField.soul], soul);
      } finally {
        try {
          if (original != null) {
            await configure(
              verifierProfile,
              description: original.values[ProfileIdentityField.description]!,
              soul: original.values[ProfileIdentityField.soul]!,
            );
            final restored = await describe(editorProfile);
            expect(
              restored.values[ProfileIdentityField.description],
              original.values[ProfileIdentityField.description],
            );
            expect(
              restored.values[ProfileIdentityField.soul],
              original.values[ProfileIdentityField.soul],
            );
          }
        } catch (error) {
          cleanupFailure = error;
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          verifierServer.close();
          editorServer.close();
          verifierStatus.dispose();
          editorStatus.dispose();
        }
        if (cleanupFailure != null) {
          fail('Profile editor live cleanup failed: $cleanupFailure');
        }
      }
    },
    skip: port == 0,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
