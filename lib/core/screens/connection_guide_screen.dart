import '../widgets/selection_viewport.dart';
import '../widgets/wing_app_bar.dart';
import 'package:flutter/material.dart';

import '../widgets/web_link_scope.dart';
import '../theme/wing_theme.dart';
import '../widgets/studio_error.dart';
import '../widgets/wing_wordmark.dart';

/// Available offline before the first host is configured.
class ConnectionGuideScreen extends StatelessWidget {
  const ConnectionGuideScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final tokens = WingTokens.of(context);
    final textTheme = Theme.of(context).textTheme;
    return Scaffold(
      appBar: WingAppBar(
        context: context,
        title: const Text('Connection guide'),
      ),
      body: SafeArea(
        top: false,
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: viewportSelection(
                SelectionArea(
                  child: DefaultTextStyle.merge(
                    style: textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w400,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const Align(
                          alignment: AlignmentDirectional.centerStart,
                          child: WingFeathers(width: 40),
                        ),
                        const SizedBox(height: 16),
                        Semantics(
                          header: true,
                          child: Text(
                            'Connect in three steps',
                            style: textTheme.titleLarge,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'You’ll need your Hermes gateway Webapp address and login.',
                          style: textTheme.bodyMedium?.copyWith(
                            color: tokens.muted,
                          ),
                        ),
                        const SizedBox(height: 32),
                        const _GuideStep(
                          number: '1',
                          title: 'Prepare your agent',
                          children: [
                            Text(
                              'On a Hermes host you’re allowed to use, check that '
                              'your agent can answer a message.',
                            ),
                          ],
                        ),
                        const _GuideStep(
                          number: '2',
                          title: 'Find your gateway Webapp address',
                          children: [
                            Text(
                              'Enable the Webapp on your Hermes gateway. Open it '
                              'in your phone’s browser and check that you can sign in. '
                              'A standalone Dashboard cannot open Wing chats.',
                            ),
                            SizedBox(height: 16),
                            _AddressExamples(),
                            SizedBox(height: 16),
                            _GuidePoint(
                              lead: 'Keep the full address. ',
                              text:
                                  'Include any custom port, such as :9120, '
                                  'and any path after the hostname.',
                            ),
                            SizedBox(height: 12),
                            _GuidePoint(
                              lead: 'Use your computer’s network address. ',
                              text:
                                  'localhost on your phone means the phone itself.',
                            ),
                            SizedBox(height: 12),
                            _GuidePoint(
                              lead: 'Connecting remotely? ',
                              text:
                                  'Use HTTPS or an encrypted private network.',
                            ),
                          ],
                        ),
                        const _GuideStep(
                          number: '3',
                          title: 'Connect in Wing',
                          children: [
                            _GuidePoint(
                              lead: 'Connect your agent',
                              text:
                                  ' on the welcome screen starts setup. '
                                  'Enter your gateway Webapp address, then sign in.',
                            ),
                            SizedBox(height: 12),
                            _GuidePoint(
                              lead: 'Check the connection. ',
                              text:
                                  'Wing checks your profiles, live chat and history.',
                            ),
                            SizedBox(height: 12),
                            _GuidePoint(
                              lead: 'Save and open. ',
                              text:
                                  'Give the verified connection a name, '
                                  'then open your workspace.',
                            ),
                          ],
                        ),
                        DecoratedBox(
                          decoration: BoxDecoration(
                            color: tokens.raised,
                            border: Border.all(color: tokens.border),
                            borderRadius: WingRadius.card,
                          ),
                          child: ExpansionTile(
                            title: const Text('When do I need Custom setup?'),
                            tilePadding: const EdgeInsets.symmetric(
                              horizontal: 16,
                            ),
                            childrenPadding: const EdgeInsets.fromLTRB(
                              16,
                              0,
                              16,
                              16,
                            ),
                            shape: const Border(),
                            collapsedShape: const Border(),
                            children: const [
                              Text(
                                'Only when your administrator supplies extra access '
                                'settings, such as a proxy or a separate chat address. '
                                'Model-provider keys stay on your Hermes host.',
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 24),
                        Semantics(
                          header: true,
                          child: Text(
                            'Already have a backup?',
                            style: textTheme.titleMedium,
                          ),
                        ),
                        const SizedBox(height: 8),
                        const Text.rich(
                          TextSpan(
                            children: [
                              TextSpan(text: 'Choose '),
                              TextSpan(
                                text: 'Restore configuration',
                                style: TextStyle(fontWeight: FontWeight.w600),
                              ),
                              TextSpan(
                                text:
                                    ' on the welcome screen. Import your Wing '
                                    'backup and enter its passphrase if you set one.',
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 24),
                        StudioButtonPress(
                          child: IconButton.outlined(
                            onPressed: () async {
                              final opened = await WebLinkScope.open(
                                context,
                                Uri.parse(
                                  'https://github.com/tarkilhk/Wing/blob/main/docs/GETTING_STARTED.md',
                                ),
                              );
                              if (!opened && context.mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                    content: StudioError(
                                      'Could not open the guide',
                                    ),
                                  ),
                                );
                              }
                            },
                            icon: const Icon(Icons.open_in_new, size: 18),
                            tooltip: 'Full setup instructions',
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
      ),
    );
  }
}

class _GuideStep extends StatelessWidget {
  const _GuideStep({
    required this.number,
    required this.title,
    required this.children,
  });

  final String number;
  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(
            header: true,
            label: 'Step $number. $title',
            excludeSemantics: true,
            child: Row(
              children: [
                Container(
                  constraints: const BoxConstraints(
                    minWidth: 32,
                    minHeight: 32,
                  ),
                  padding: const EdgeInsets.all(4),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primaryContainer,
                    borderRadius: WingRadius.control,
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    number,
                    style: theme.textTheme.titleMedium?.copyWith(
                      color: WingTokens.of(context).accent,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(title, style: theme.textTheme.titleMedium),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          ...children,
        ],
      ),
    );
  }
}

class _GuidePoint extends StatelessWidget {
  const _GuidePoint({required this.lead, required this.text});

  final String lead;
  final String text;

  @override
  Widget build(BuildContext context) => Text.rich(
    TextSpan(
      children: [
        TextSpan(
          text: lead,
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        TextSpan(text: text),
      ],
    ),
  );
}

class _AddressExamples extends StatelessWidget {
  const _AddressExamples();

  @override
  Widget build(BuildContext context) {
    final tokens = WingTokens.of(context);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: tokens.raised,
        border: Border.all(color: tokens.border),
        borderRadius: WingRadius.card,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final (index, example) in const [
            ('Private network · example', 'http://hermes.home:9120'),
            ('HTTPS proxy · example', 'https://hermes.example.com'),
          ].indexed) ...[
            if (index > 0) const Divider(height: 24),
            Text(example.$1, style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 8),
            Text(
              example.$2,
              style: tokens.typography.mono.copyWith(color: tokens.onSurface),
            ),
          ],
        ],
      ),
    );
  }
}
