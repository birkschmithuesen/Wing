import 'package:wing/core/theme/wing_theme.dart';
import 'package:flutter/material.dart';

import '../screens/connection_guide_screen.dart';
import 'playful_portrait.dart';
import 'wing_wordmark.dart';

/// First connection only; restoring or adding a host uses the existing flows.
class WingWelcome extends StatelessWidget {
  const WingWelcome({
    super.key,
    required this.onConnect,
    required this.onRestore,
  });

  final VoidCallback onConnect;
  final VoidCallback onRestore;

  @override
  Widget build(BuildContext context) => SafeArea(
    top: false,
    child: LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: constraints.maxHeight),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 400),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const PlayfulPortrait(size: 144, circular: true),
                    const SizedBox(height: 12),
                    const WingWordmark(),
                    const SizedBox(height: 8),
                    Text(
                      'Your agent, with you',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 24),
                    const Text(
                      'Connect your Hermes host\nto bring your conversations with you',
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 24),
                    SizedBox(
                      width: double.infinity,
                      child: StudioButtonPress(
                        child: FilledButton.icon(
                          key: const Key('wing-connect'),
                          style: FilledButton.styleFrom(
                            minimumSize: const Size(48, 48),
                          ),
                          onPressed: onConnect,
                          icon: const Icon(Icons.add),
                          label: const Text(
                            'Connect your agent',
                            textAlign: TextAlign.center,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    SizedBox(
                      width: double.infinity,
                      child: StudioButtonPress(
                        child: OutlinedButton(
                          key: const Key('home_restore_config_button'),
                          style: OutlinedButton.styleFrom(
                            minimumSize: const Size(48, 48),
                          ),
                          onPressed: onRestore,
                          child: const Text(
                            'Restore configuration',
                            textAlign: TextAlign.center,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 4),
                    StudioButtonPress(
                      child: TextButton(
                        onPressed: () => Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => const ConnectionGuideScreen(),
                          ),
                        ),
                        child: const Text('Connection guide'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}
