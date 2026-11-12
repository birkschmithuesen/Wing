import 'package:wing/core/widgets/studio_loading.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'package:wing/core/widgets/installed_app_version_card.dart';

void main() {
  testWidgets(
    'metadata arrives without moving or withholding release actions',
    (tester) async {
      PackageInfo.setMockInitialValues(
        appName: 'Wing',
        packageName: 'com.tarkilhk.wing',
        version: '1.2.0',
        buildNumber: '24722',
        buildSignature: '',
      );
      final opened = <Uri>[];
      final card = GlobalKey();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 320,
                child: InstalledAppVersionCard(
                  key: card,
                  openLink: (uri) async {
                    opened.add(uri);
                    return true;
                  },
                ),
              ),
            ),
          ),
        ),
      );
      final before = tester.getRect(find.byKey(card));
      expect(find.byType(StudioLoading), findsNothing);
      expect(find.text('Version —'), findsOneWidget);
      await tester.tap(find.text('Releases'));
      expect(opened, [Uri.parse('https://github.com/tarkilhk/Wing/releases')]);
      await tester.pumpAndSettle();
      expect(find.text('Version 1.2.0'), findsOneWidget);
      expect(tester.getRect(find.byKey(card)), before);
    },
  );
  testWidgets('shows the public version and keeps the Android build internal', (
    tester,
  ) async {
    PackageInfo.setMockInitialValues(
      appName: 'Wing',
      packageName: 'com.example.hermes',
      version: '1.0.0',
      buildNumber: '22332',
      buildSignature: '',
      installerStore: '',
    );

    await tester.pumpWidget(const MaterialApp(home: InstalledAppVersionCard()));
    expect(find.text('Loading version information…'), findsNothing);
    expect(find.byType(StudioLoading), findsNothing);
    expect(
      find.bySemanticsLabel(RegExp('Loading version information')),
      findsNothing,
    );
    await tester.pumpAndSettle();

    expect(find.text('Wing'), findsOneWidget);
    expect(find.text('Version 1.0.0'), findsOneWidget);
    expect(find.textContaining('22332'), findsNothing);
    expect(find.textContaining('com.example.hermes'), findsNothing);
  });

  testWidgets('keeps a compact card layout at large text', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    PackageInfo.setMockInitialValues(
      appName: 'Wing',
      packageName: 'com.example.hermes',
      version: '2.9.0',
      buildNumber: '2158',
      buildSignature: '',
      installerStore: '',
    );

    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(2)),
          child: const SingleChildScrollView(child: InstalledAppVersionCard()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('Wing'), findsOneWidget);
  });

  testWidgets("opens this fork's changelog and release pages", (tester) async {
    PackageInfo.setMockInitialValues(
      appName: 'Wing',
      packageName: 'com.tarkilhk.wing',
      version: '2.30.0',
      buildNumber: '2182',
      buildSignature: '',
      installerStore: '',
    );
    final opened = <Uri>[];

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: InstalledAppVersionCard(
            openLink: (uri) async {
              opened.add(uri);
              return true;
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text("What's new"));
    await tester.pump();
    await tester.tap(find.text('Releases'));
    await tester.pump();

    expect(opened, [
      Uri.parse('https://github.com/tarkilhk/Wing/blob/main/CHANGELOG.md'),
      Uri.parse('https://github.com/tarkilhk/Wing/releases'),
    ]);
  });

  testWidgets('reports when a release link cannot open', (tester) async {
    PackageInfo.setMockInitialValues(
      appName: 'Wing',
      packageName: 'com.tarkilhk.wing',
      version: '2.30.0',
      buildNumber: '2182',
      buildSignature: '',
      installerStore: '',
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: InstalledAppVersionCard(openLink: (_) async => false),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Releases'));
    await tester.pumpAndSettle();

    expect(find.text('Could not open this link.'), findsOneWidget);
  });
}
