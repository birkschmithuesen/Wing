import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/models/gateway_sensitive_prompt.dart';
import 'package:wing/core/widgets/gateway_sensitive_prompt_panel.dart';

void main() {
  const sudo = GatewaySensitivePromptRequest(
    kind: GatewaySensitivePromptKind.sudo,
    requestId: 'sudo-1',
    title: 'Administrator password needed',
    description: 'Hermes needs a sudo password.',
    fieldLabel: 'Sudo password',
  );

  Widget app(
    GatewaySensitivePromptRequest request,
    SensitivePromptResponder respond,
  ) => MaterialApp(
    home: Scaffold(
      body: GatewaySensitivePromptPanel(request: request, onRespond: respond),
    ),
  );

  testWidgets('password input disables disclosure through suggestions', (
    tester,
  ) async {
    await tester.pumpWidget(app(sudo, (_) async {}));
    final field = tester.widget<TextField>(
      find.byKey(const Key('sensitive-prompt-field')),
    );
    expect(field.obscureText, isTrue);
    expect(field.autocorrect, isFalse);
    expect(field.enableSuggestions, isFalse);
  });

  testWidgets('pending response gives feedback and rejects repeat actions', (
    tester,
  ) async {
    final pending = Completer<void>();
    addTearDown(() {
      if (!pending.isCompleted) pending.complete();
    });
    final values = <String>[];
    await tester.pumpWidget(
      app(sudo, (value) {
        values.add(value);
        return pending.future;
      }),
    );
    await tester.enterText(
      find.byKey(const Key('sensitive-prompt-field')),
      'synthetic-password',
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('sensitive-prompt-submit')));
    await tester.pump();

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    await tester.tap(find.byKey(const Key('sensitive-prompt-submit')));
    await tester.tap(find.byKey(const Key('sensitive-prompt-cancel')));
    await tester.pump(const Duration(seconds: 2));
    expect(values, ['synthetic-password']);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    pending.complete();
    await tester.pump();
  });

  testWidgets('cancel sends the explicit empty response', (tester) async {
    final values = <String>[];
    await tester.pumpWidget(app(sudo, (value) async => values.add(value)));

    await tester.tap(find.byKey(const Key('sensitive-prompt-cancel')));
    await tester.pump();

    expect(values, ['']);
  });

  testWidgets('shows a generic error without rendering the exception', (
    tester,
  ) async {
    await tester.pumpWidget(
      app(sudo, (_) => Future<void>.error('server echoed a credential')),
    );
    await tester.enterText(
      find.byKey(const Key('sensitive-prompt-field')),
      'fixture-secret',
    );
    await tester.pump();

    await tester.tap(find.byKey(const Key('sensitive-prompt-submit')));
    await tester.pump();

    expect(
      tester
          .widget<Text>(
            find.descendant(
              of: find.byKey(const Key('sensitive-prompt-error')),
              matching: find.byType(Text),
            ),
          )
          .data,
      'Hermes could not accept the response. Please try again.',
    );
    expect(find.textContaining('server echoed'), findsNothing);
  });

  testWidgets('a newer request clears the prior value and remains usable', (
    tester,
  ) async {
    await tester.pumpWidget(app(sudo, (_) async {}));
    await tester.enterText(
      find.byKey(const Key('sensitive-prompt-field')),
      'old-value',
    );
    const secret = GatewaySensitivePromptRequest(
      kind: GatewaySensitivePromptKind.secret,
      requestId: 'secret-2',
      title: 'FIXTURE_TOKEN',
      description: 'Enter a token.',
      fieldLabel: 'FIXTURE_TOKEN',
    );

    await tester.pumpWidget(app(secret, (_) async {}));

    expect(
      tester
          .widget<TextField>(find.byKey(const Key('sensitive-prompt-field')))
          .controller!
          .text,
      isEmpty,
    );
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('sensitive-prompt-field')))
          .enabled,
      isTrue,
    );
  });

  for (final fails in [false, true]) {
    testWidgets(
      'late ${fails ? 'failure' : 'success'} cannot clear a newer secret draft',
      (tester) async {
        final pending = Completer<void>();
        addTearDown(() {
          if (!pending.isCompleted) pending.complete();
        });
        await tester.pumpWidget(app(sudo, (_) => pending.future));
        await tester.enterText(
          find.byKey(const Key('sensitive-prompt-field')),
          'old-secret',
        );
        await tester.pump();
        await tester.tap(find.byKey(const Key('sensitive-prompt-submit')));
        await tester.pump();
        const newer = GatewaySensitivePromptRequest(
          kind: GatewaySensitivePromptKind.secret,
          requestId: 'new-request',
          title: 'New token',
          description: 'Enter a new token.',
          fieldLabel: 'Token',
        );
        final responses = <String>[];
        await tester.pumpWidget(
          app(newer, (value) async => responses.add(value)),
        );
        await tester.enterText(
          find.byKey(const Key('sensitive-prompt-field')),
          'new-secret',
        );
        if (fails) {
          pending.completeError(StateError('old request failed'));
        } else {
          pending.complete();
        }
        await tester.pump();
        expect(find.byKey(const Key('sensitive-prompt-error')), findsNothing);
        await tester.tap(find.byKey(const Key('sensitive-prompt-submit')));
        await tester.pump();
        expect(responses, ['new-secret']);
      },
    );
  }

  testWidgets('the same recovered request preserves the typed value', (
    tester,
  ) async {
    await tester.pumpWidget(app(sudo, (_) async {}));
    await tester.enterText(
      find.byKey(const Key('sensitive-prompt-field')),
      'still-typing',
    );
    const refreshed = GatewaySensitivePromptRequest(
      kind: GatewaySensitivePromptKind.sudo,
      requestId: 'sudo-1',
      title: 'Administrator password still needed',
      description: 'The same request remains pending.',
      fieldLabel: 'Sudo password',
    );

    await tester.pumpWidget(app(refreshed, (_) async {}));

    expect(
      tester
          .widget<TextField>(find.byKey(const Key('sensitive-prompt-field')))
          .controller!
          .text,
      'still-typing',
    );
  });

  testWidgets('save login submits a trimmed identifier and masked password', (
    tester,
  ) async {
    const request = GatewaySensitivePromptRequest(
      kind: GatewaySensitivePromptKind.vaultSaveLogin,
      requestId: 'save-1',
      title: 'Save login for Example',
      description: 'Save a login for Example.',
      fieldLabel: 'Identifier',
    );
    final responses = <String>[];
    await tester.pumpWidget(
      app(request, (value) async => responses.add(value)),
    );

    expect(
      tester
          .widget<TextField>(find.byKey(const Key('sensitive-prompt-field')))
          .obscureText,
      isFalse,
    );
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('sensitive-prompt-password')))
          .obscureText,
      isTrue,
    );
    await tester.enterText(
      find.byKey(const Key('sensitive-prompt-field')),
      '  person@example.test  ',
    );
    await tester.enterText(
      find.byKey(const Key('sensitive-prompt-password')),
      'synthetic-password',
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('sensitive-prompt-submit')));
    await tester.pump();

    expect(jsonDecode(responses.single), {
      'identifier': 'person@example.test',
      'password': 'synthetic-password',
    });
  });

  testWidgets('one-time code stays visible and removes spaces and hyphens', (
    tester,
  ) async {
    const request = GatewaySensitivePromptRequest(
      kind: GatewaySensitivePromptKind.vaultCode,
      requestId: 'code-1',
      title: 'Enter code for Example',
      description: 'Enter a one-time code.',
      fieldLabel: 'One-time code',
    );
    final responses = <String>[];
    await tester.pumpWidget(
      app(request, (value) async => responses.add(value)),
    );

    expect(
      tester
          .widget<TextField>(find.byKey(const Key('sensitive-prompt-field')))
          .obscureText,
      isFalse,
    );
    await tester.enterText(
      find.byKey(const Key('sensitive-prompt-field')),
      '123 456-78',
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('sensitive-prompt-submit')));
    await tester.pump();

    expect(responses, ['12345678']);
  });
}
