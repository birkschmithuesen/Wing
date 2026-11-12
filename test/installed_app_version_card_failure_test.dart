import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/theme/wing_theme.dart';
import 'package:wing/core/widgets/installed_app_version_card.dart';
import 'package:wing/core/widgets/studio_error.dart';

import 'support/form_family_capture.dart';

// PackageInfo caches successful reads for the isolate. Run failed platform
// reads separately from the tests that seed that cache.
void main() {
  setUpAll(loadFormFamilyFonts);

  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('package read failure ${brightness.name} $scale', (
        tester,
      ) async {
        const channel = MethodChannel('dev.fluttercommunity.plus/package_info');
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          (_) async => throw PlatformException(code: 'metadata_unavailable'),
        );
        addTearDown(() {
          tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            channel,
            null,
          );
        });
        tester.view.physicalSize = Size(scale == 2 ? 320 : 390, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final opened = <Uri>[];
        await tester.pumpWidget(
          MaterialApp(
            theme: wingTheme(brightness),
            debugShowCheckedModeBanner: false,
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(scale)),
              child: RepaintBoundary(key: formFamilyCapture, child: child!),
            ),
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
        expect(find.text('Version —'), findsOneWidget);
        await tester.pumpAndSettle();
        expect(
          find.descendant(
            of: find.byType(StudioError),
            matching: find.text('Version information is unavailable.'),
          ),
          findsOneWidget,
        );
        await captureFormFamily(
          tester,
          'installed-version-error-${brightness.name}-$scale',
        );
        await tester.tap(find.text('Releases'));
        expect(opened.single.path, '/tarkilhk/Wing/releases');
        expect(tester.takeException(), isNull);
      });
    }
  }
}
