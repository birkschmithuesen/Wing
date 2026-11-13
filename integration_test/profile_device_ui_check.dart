/// Manual Android UI checks using the shipped screen/controller and an isolated
/// gateway fixture. Build as a debug entry point, install with adb install -r,
/// and restore lib/main.dart afterward. Never install this in Wing.
library;

import '../test/support/composer_fixture.dart';

import 'package:wing/core/models/profile_session_key.dart';

import 'package:wing/core/services/app_preferences.dart';
import 'package:wing/core/services/bots_session.dart';

import 'package:wing/core/services/connection_access.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wing/core/models/hermes_profile.dart';
import 'package:wing/core/screens/profile_workspace_screen.dart';
import 'package:wing/core/services/connection_manager.dart';
import 'package:wing/core/services/profile_gateway.dart';
import 'package:wing/core/services/profile_workspace_controller.dart';
import 'package:wing/core/services/ws_client.dart';
import 'package:wing/core/theme/wing_theme.dart';
import '../test/support/profile_browser_fixture.dart';

class DeviceFixture extends ProfileBrowserFixture {
  ProfileGateway? active;
  int replies = 0;
  @override
  List<Map<String, dynamic>> historyRows(String profile, String id) => [
    {'id': 1, 'role': 'user', 'content': 'Review the landing page only.'},
    {
      'id': 2,
      'role': 'tool',
      'tool_name': 'Read project',
      'content': 'Disposable device test',
    },
    {
      'id': 3,
      'role': 'tool',
      'tool_name': 'Inspect files',
      'content': 'No server request',
    },
    {
      'id': 4,
      'role': 'assistant',
      'content':
          '## Keep the review focused\n\nThe landing page is the current review. Other routes are **future work**.\n\n'
          '> Navigation currently opens the prototype. This matters before publishing, but it should not interrupt the landing-page review.\n\n'
          '### Next steps\n\n- Review the `/target/` landing page.\n- Keep the agreed scope.\n\n'
          '---\n\n| Area | Status |\n| --- | --- |\n| Landing page | In review |\n| Other routes | Planned |\n\n'
          '```dart\nfinal profile = "personal";\n```',
    },
  ];

  @override
  ProfileGateway gateway(WorkspaceScope scope) {
    final base = super.gateway(scope);
    return active = ProfileGateway(
      scope: scope,
      discover: base.discover,
      get: base.read,
      rpc: (method, params) async {
        if (method != 'clarify.lock') return base.call(method, params);
        if (params['profile'] != 'personal' ||
            params['session_id'] != 'runtime' ||
            params['request_id'] != 'device-question') {
          throw StateError('Device QA response identity mismatch');
        }
        replies++;
        debugPrint(
          'DEVICE_QA reply=$replies question=${params['question_id']} answer=${params['answer']}',
        );
        if (replies == 1) throw StateError('Authored retry test');
        return {
          'status': 'ok',
          'remaining': params['question_id'] == 'q1' ? ['q2'] : [],
        };
      },
    );
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // No disk credentials or production configuration are read or written.
  SharedPreferences.setMockInitialValues({});
  final preferences = await SharedPreferences.getInstance();
  runApp(
    DeviceCheck(
      preferences: preferences,
      appPreferences: AppPreferences(preferences),
    ),
  );
}

class DeviceCheck extends StatefulWidget {
  const DeviceCheck({
    required this.preferences,
    required this.appPreferences,
    super.key,
  });
  final SharedPreferences preferences;
  final AppPreferences appPreferences;
  @override
  State<DeviceCheck> createState() => _DeviceCheckState();
}

class _DeviceCheckState extends State<DeviceCheck> {
  ProfileWorkspaceController? controller;
  final _ownedControllers = <ProfileWorkspaceController>{};
  bool _opening = false;
  Brightness brightness = Brightness.dark;
  double scale = 1;
  Future<void> open({
    bool question = false,
    bool light = false,
    bool large = false,
  }) async {
    if (_opening) return;
    _opening = true;
    ProfileWorkspaceController? candidate;
    try {
      final fixture = DeviceFixture();
      final next = ProfileWorkspaceController(
        access: ConnectionAccess(
          connection: SavedConnection(
            id: 'device-check',
            label: 'Device QA',
            host: 'unused',
            port: 1,
            apiKey: '',
          ),
          dashboardOAuth: null,
        ),
        connectionIdentity: 'isolated-device-check',
        preferences: widget.preferences,
        appPreferences: widget.appPreferences,
        gatewayFactory: fixture.gateway,
      );
      candidate = next;
      _ownedControllers.add(next);
      await next.initialize();
      if (!mounted) return;
      await next.openSession(
        ProfileSessionKey(next.current!.scope, 'device-check'),
      );
      if (!mounted) return;
      final chat = next.current!.chat!;
      emitChatEvent(next, chat, 'session.title', {
        'session_id': chat.key.sessionId,
        'title': question ? 'Question device check' : 'Markdown device check',
      });
      if (question) {
        fixture.active!.onEvent!(
          StreamEvent(
            type: 'clarify',
            sessionId: chat.runtime.runtimeId,
            data: {
              'request_id': 'device-question',
              'questions': [
                {
                  'qid': 'q1',
                  'question':
                      'The landing page is ready for a design and copy review. The other routes still belong to an earlier prototype and are outside the current scope. Which type of review should I run before we continue?',
                  'choices': [
                    'Detailed review of layout and copy (Recommended)',
                    'Quick review of the main issues',
                    'Wait until the other routes are ready',
                  ],
                },
                {
                  'qid': 'q2',
                  'question': 'Which areas should I focus on?',
                  'choices': ['Layout', 'Copy', 'Accessibility'],
                  'multi_select': true,
                },
              ],
            },
          ),
        );
      }
      final previous = controller;
      setState(() {
        controller = next;
        brightness = light ? Brightness.light : Brightness.dark;
        scale = large ? 2 : 1;
      });
      if (previous != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_ownedControllers.remove(previous)) previous.dispose();
        });
      }
      debugPrint(
        'DEVICE_QA ready question=$question light=$light large=$large',
      );
    } finally {
      if (candidate != null &&
          candidate != controller &&
          _ownedControllers.remove(candidate)) {
        candidate.dispose();
      }
      _opening = false;
    }
  }

  @override
  void dispose() {
    for (final owned in _ownedControllers) {
      owned.dispose();
    }
    _ownedControllers.clear();
    widget.appPreferences.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: wingTheme(brightness),
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(
        context,
      ).copyWith(textScaler: TextScaler.linear(scale)),
      child: child!,
    ),
    home: controller == null
        ? Scaffold(
            body: SafeArea(
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text('Isolated Android device check'),
                    FilledButton(
                      onPressed: () => open(),
                      child: const Text('Dark quotes'),
                    ),
                    FilledButton(
                      onPressed: () => open(light: true),
                      child: const Text('Light quotes'),
                    ),
                    FilledButton(
                      onPressed: () => open(question: true),
                      child: const Text('Questions and retry'),
                    ),
                    FilledButton(
                      onPressed: () => open(question: true, large: true),
                      child: const Text('Questions large text'),
                    ),
                  ],
                ),
              ),
            ),
          )
        : ProfileWorkspaceScreen(
            controller: controller!,
            createBotsSession: () => BotsSession((_) async => const []),
          ),
  );
}
