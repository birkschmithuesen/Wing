import 'package:wing/core/theme/wing_theme.dart';
import 'package:flutter/material.dart';
import '../../models/bots.dart';
import '../../models/profiles_management.dart';
import '../../services/administration_repository.dart';
import '../../services/bot_profile_edit_session.dart';
import '../../services/bots_session.dart';
import '../../services/profiles_management_session.dart';
import '../../services/android_voice.dart';
import '../../services/profile_capabilities_session.dart';
import '../../services/profile_identity_edit_session.dart';
import '../../services/profile_plugins_session.dart';
import '../../services/profile_skills_session.dart';
import '../../services/profile_tool_setup_session.dart';
import '../../widgets/server_connection_label.dart';
import '../../widgets/wing_app_bar.dart';
import '../profile_capabilities_screen.dart';
import '../administration/admin_profiles_page.dart';
import 'bot_profile_editor.dart';
import 'bots_create_screen.dart';
import '../administration/admin_defaults_page.dart';
import '../administration/admin_hosted_connector_accounts_page.dart';
import '../administration/admin_connector_routes.dart';
import '../administration/admin_identity_page.dart';
import '../administration/admin_plugins_page.dart';
import '../administration/admin_provider_credentials.dart';
import '../administration/admin_providers_page.dart';
import '../administration/admin_skills_page.dart';
import '../administration/admin_tool_setup_page.dart';
import '../administration/admin_voice_routes.dart';

/// Settings handoff to Wing's established captured-profile editors. No copied
/// account/model/settings form and no mutation of the selected chat's profile.
class BotSettingsScreen extends StatefulWidget {
  const BotSettingsScreen({
    super.key,
    required this.profile,
    required this.bot,
    required this.session,
  });
  final ProfileAdministration profile;
  final BotRecord bot;
  final BotsSession session;
  @override
  State<BotSettingsScreen> createState() => _BotSettingsScreenState();
}

class _BotSettingsScreenState extends State<BotSettingsScreen> {
  ProfileAdministration get profile => widget.profile;
  late BotRecord _bot = widget.bot;

  Future<void> _appearance() async {
    late BotProfileEditSession editor;
    await _push(
      context,
      BotProfileEditor(
        createSession: () => editor = BotProfileEditSession(
          widget.session.repository(_bot.scope.connectionIdentity),
          _bot,
          avatars: widget.session.createAvatarBorrower(),
          validateImage: (bot) => widget.session.reloadAvatar(bot.scope),
          onSaved: (bot, image, assetSaved) => widget.session.acceptAppearance(
            bot,
            image: image,
            assetSaved: assetSaved,
          ),
        ),
      ),
    );
    if (mounted) setState(() => _bot = editor.bot);
  }

  Future<void> _manage(ProfileManagementEntry action) async {
    late ProfilesManagementSession management;
    await _push(
      context,
      AdminProfilesPage(
        initialProfile: profile.name,
        initialAction: action,
        createSession: () => management = ProfilesManagementSession(
          server: profile.server,
          openProfile: (_) async => true,
        ),
      ),
    );
    final outcome = management.state.outcome;
    if (mounted &&
        (outcome?.announcesSuccess == true ||
            outcome?.kind ==
                ProfilesManagementOutcomeKind.deletedSettlementPending)) {
      Navigator.pop(context);
    }
  }

  Widget _scoped(Widget child) {
    final status = profile.gateway.connectionStatus;
    return status == null
        ? child
        : ServerConnectionScope(status: status, child: child);
  }

  Future<void> _push(BuildContext context, Widget child) async {
    await Navigator.push<void>(
      context,
      MaterialPageRoute(builder: (_) => _scoped(child)),
    );
  }

  Widget _capabilities(BuildContext context) => ProfileCapabilitiesScreen(
    createSession: () => ProfileCapabilitiesSession(profile.gateway),
    connectionLabel: profile.server.connectionLabel,
    onConnectedApps: () =>
        _push(context, AdminHostedConnectorAccountsPage(profile: profile)),
    onMcpConnectors: () => _push(context, profileConnectorsPage(profile)),
    onToolSetup: (name) => _push(
      context,
      name == 'tts'
          ? profileSpeechSynthesisPage(profile, device: AndroidVoice.instance)
          : AdminToolSetupPage(
              createSession: () => ProfileToolSetupSession(profile, tool: name),
              onCredential: (context, field) => _push(
                context,
                AdminSecretPage(profile: profile, name: field.key),
              ),
            ),
    ),
    onLibrary: () => _push(
      context,
      AdminSkillLibraryPage(
        createSession: () => ProfileSkillsSession.library(profile),
      ),
    ),
    onHub: () => _push(
      context,
      AdminSkillHubPage(createSession: () => ProfileSkillsSession.hub(profile)),
    ),
    onPlugins: () => _push(
      context,
      AdminPluginsPage(createSession: () => ProfilePluginsSession(profile)),
    ),
  );
  @override
  Widget build(BuildContext context) => _scoped(
    Scaffold(
      appBar: WingAppBar(context: context, title: const Text('Bot settings')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(profile.label, style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 16),
          StudioButtonPress(
            child: ListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Edit name & appearance'),
              subtitle: const Text('Display name, shape, color and avatar'),
              trailing: const Icon(Icons.chevron_right),
              onTap: _appearance,
            ),
          ),
          for (final (title, subtitle, icon, page)
              in <(String, String, IconData, Widget Function())>[
                (
                  'Role & instructions',
                  'Description and SOUL.md',
                  Icons.badge_outlined,
                  () => AdminIdentityPage(
                    createSession: () => ProfileIdentityEditSession(profile),
                  ),
                ),
                (
                  'Model & defaults',
                  'Main model and helper models',
                  Icons.tune_outlined,
                  () => AdminDefaultsPage(profile: profile),
                ),
                (
                  'Accounts & credentials',
                  'Provider access for this bot',
                  Icons.key_outlined,
                  () => AdminProvidersPage(profile: profile),
                ),
                (
                  'Skills & tools',
                  'Capabilities, library, hub and plugins',
                  Icons.extension_outlined,
                  () => _capabilities(context),
                ),
                (
                  'MCP connectors',
                  'Status, tools, authentication and access',
                  Icons.link,
                  () => profileConnectorsPage(profile),
                ),
              ])
            StudioButtonPress(
              child: ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(icon),
                title: Text(title),
                subtitle: Text(subtitle),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => _push(context, page()),
              ),
            ),
          const Divider(),
          StudioButtonPress(
            child: ListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Duplicate bot'),
              subtitle: const Text('Create a bot from this configuration'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => _push(
                context,
                BotsCreateScreen(
                  session: widget.session,
                  group: false,
                  clone: _bot,
                ),
              ),
            ),
          ),
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            title: const Text('Advanced'),
            children: [
              StudioButtonPress(
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Rename profile'),
                  subtitle: Text(
                    profile.name == 'default'
                        ? 'Change the default profile’s display name'
                        : 'Change the underlying profile name',
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => _manage(ProfileManagementEntry.rename),
                ),
              ),
            ],
          ),
          const Divider(),
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(
              'Delete bot',
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
            subtitle: Text(
              profile.name == 'default'
                  ? 'The default profile cannot be deleted'
                  : 'Delete this profile. Confirmation required.',
            ),
            trailing: StudioButtonPress(
              child: IconButton(
                tooltip: 'Delete bot',
                icon: const Icon(Icons.delete_outline),
                color: Theme.of(context).colorScheme.error,
                onPressed: profile.name == 'default'
                    ? null
                    : () => _manage(ProfileManagementEntry.delete),
              ),
            ),
          ),
        ],
      ),
    ),
  );
}
