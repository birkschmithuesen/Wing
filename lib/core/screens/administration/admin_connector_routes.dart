import 'package:flutter/widgets.dart';
import '../../models/profile_connectors.dart';
import '../../services/administration_repository.dart';
import '../../services/profile_connectors_session.dart';
import 'admin_connectors_page.dart';
import 'admin_mcp_setup_page.dart';
import 'admin_navigation.dart';

/// Composition captures the server; explicit picker selections issue new owners.
Widget profileConnectorsPage(
  ProfileAdministration profile, {
  Set<String> failedConnectorNames = const {},
}) => AdminConnectorsPage(
  failedConnectorNames: failedConnectorNames,
  createSession: () => ProfileConnectorsSession(profile),
  pushDetail: (context, initial, createRoute) async {
    await adminPushProfile<void>(
      context,
      profile.server.profile(initial),
      (_, selected) =>
          AdminConnectorDetail(createRoute: () => createRoute(selected.name)),
    );
  },
  pushSetup: (context, createSession) =>
      adminPushProfile<(String, ProfileConnector)>(
        context,
        profile,
        (_, selected) => AdminMcpSetupPage(
          createSession: () => createSession(selected.name),
        ),
      ),
);

Widget profileConnectorIssuePage(
  ProfileAdministration profile,
  List<String> names,
) => names.length == 1
    ? AdminConnectorDetail(
        createRoute: () => ProfileConnectorsSession.openStandaloneDetail(
          profile,
          names.single,
        ),
      )
    : profileConnectorsPage(profile, failedConnectorNames: names.toSet());
