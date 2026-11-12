import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:wing/core/models/hermes_profile.dart';
import 'package:wing/core/services/app_preferences.dart';
import 'package:wing/core/services/profile_colors_session.dart';
import 'package:wing/core/theme/wing_theme.dart';
import 'package:wing/core/widgets/profile_selector.dart';

const _connection = 'colour-owner-a';
String _key(String identity) =>
    'profile_color_v1_${sha256.convert(utf8.encode(identity))}_work';

Future<(SharedPreferences, _Storage)> _preferences({
  required int initial,
  bool rejectBlue = false,
  bool rejectRestoration = false,
}) async {
  SharedPreferences.resetStatic();
  final platform = _Storage(
    initial: initial,
    rejectBlue: rejectBlue,
    rejectRestoration: rejectRestoration,
  );
  SharedPreferencesStorePlatform.instance = platform;
  final preferences = await SharedPreferences.getInstance();
  addTearDown(() {
    if (!platform.reloadRelease.isCompleted) platform.reloadRelease.complete();
    SharedPreferences.setMockInitialValues({});
  });
  return (preferences, platform);
}

Widget _selector(ProfileColorsSession Function() colors) => ProfileSelector(
  key: const ValueKey('colour-selector'),
  profiles: const [HermesProfile(name: 'work', displayName: 'Work')],
  selectedProfile: 'work',
  onSelected: (_) {},
  createColors: colors,
);

Future<void> _show(
  WidgetTester tester,
  ProfileColorsSession Function() colors, {
  Brightness brightness = Brightness.light,
  double scale = 1,
}) => tester.pumpWidget(
  RepaintBoundary(
    key: const ValueKey('colour-preview'),
    child: MaterialApp(
      theme: wingTheme(brightness),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(scale)),
        child: child!,
      ),
      home: Scaffold(body: _selector(colors)),
    ),
  ),
);

Future<void> _open(WidgetTester tester) async {
  await tester.longPress(find.byKey(const ValueKey('profile-work')));
  await tester.pumpAndSettle();
  expect(find.text('Color for Work'), findsOneWidget);
}

Semantics _semantics(WidgetTester tester, String label) =>
    tester.widget<Semantics>(
      find.byWidgetPredicate(
        (widget) => widget is Semantics && widget.properties.label == label,
      ),
    );

bool? _selected(WidgetTester tester, String label) =>
    _semantics(tester, label).properties.selected;

AppPreferences _owner(SharedPreferences preferences) {
  final owner = AppPreferences(preferences);
  addTearDown(owner.dispose);
  return owner;
}

ProfileColorsSession Function() _factory(
  AppPreferences owner,
  String identity,
) =>
    () =>
        ProfileColorsSession(preferences: owner, connectionIdentity: identity);

Future<void> _captureFrame(WidgetTester tester, String name) async {
  if (!const bool.fromEnvironment('CAPTURE_PROFILE_COLOURS')) return;
  await tester.runAsync(() async {
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(const ValueKey('colour-preview')),
    );
    final image = await boundary.toImage(pixelRatio: 2);
    try {
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      final file = File('build/architecture-program/colour-render/$name.png');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(data!.buffer.asUint8List());
    } finally {
      image.dispose();
    }
  });
}

void main() {
  if (const bool.fromEnvironment('CAPTURE_PROFILE_COLOURS')) {
    setUpAll(() async {
      const directory = String.fromEnvironment('CAPTURE_FONT_DIR');
      for (final font in {
        'Roboto': 'roboto-regular.ttf',
        'MaterialIcons': 'materialicons-regular.otf',
      }.entries) {
        await (FontLoader(font.key)..addFont(
              File(
                '$directory/${font.value}',
              ).readAsBytes().then((bytes) => bytes.buffer.asByteData()),
            ))
            .load();
      }
    });
  }
  testWidgets('a rejected colour write retains the confirmed picker choice', (
    tester,
  ) async {
    final (preferences, storage) = await _preferences(
      initial: 3,
      rejectBlue: true,
    );
    await _show(tester, _factory(_owner(preferences), _connection));
    await _open(tester);
    expect(_selected(tester, 'Lime'), isTrue);
    await tester.tap(find.byKey(const ValueKey('profile-color-8')));
    await tester.pumpAndSettle();
    expect(find.text('Could not save the profile color.'), findsOneWidget);
    expect((await storage.getAll())['flutter.${_key(_connection)}'], 3);
    await _open(tester);
    expect(_selected(tester, 'Lime'), isTrue);
    expect(_selected(tester, 'Blue'), isFalse);
  });

  testWidgets('choosing Automatic repairs a malformed stored colour', (
    tester,
  ) async {
    final (preferences, storage) = await _preferences(initial: 99);
    await _show(tester, _factory(_owner(preferences), _connection));
    await _open(tester);
    await tester.tap(find.byKey(const ValueKey('profile-color-automatic')));
    await tester.pumpAndSettle();
    expect(preferences.containsKey(_key(_connection)), isFalse);
    expect(
      (await storage.getAll()).containsKey('flutter.${_key(_connection)}'),
      isFalse,
    );
  });

  testWidgets('an uncertain colour save offers an actionable reload', (
    tester,
  ) async {
    final (preferences, _) = await _preferences(
      initial: 3,
      rejectBlue: true,
      rejectRestoration: true,
    );
    final owner = _owner(preferences);
    await _show(tester, _factory(owner, _connection));
    await _open(tester);
    await tester.tap(find.byKey(const ValueKey('profile-color-8')));
    await tester.pumpAndSettle();
    expect(
      find.text('Could not verify the profile color. Reload settings.'),
      findsOneWidget,
    );
    expect(owner.current.reloadControl.visible, isFalse);
    await _open(tester);
    expect(_selected(tester, 'Lime'), isFalse);
    expect(find.text('Reload colors'), findsOneWidget);
    await tester.tap(find.text('Reload colors'));
    await tester.pumpAndSettle();
    expect(_selected(tester, 'Lime'), isTrue);
    expect(
      find.text('Reload settings to verify this profile color.'),
      findsNothing,
    );
    expect(find.text('Reload colors'), findsNothing);
  });

  for (final (brightness, scale) in [
    (Brightness.light, 1.0),
    (Brightness.dark, 1.0),
    (Brightness.light, 2.0),
    (Brightness.dark, 2.0),
  ]) {
    testWidgets('uncertain colour picker ${brightness.name} $scale', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final (preferences, _) = await _preferences(
        initial: 3,
        rejectBlue: true,
        rejectRestoration: true,
      );
      await _show(
        tester,
        _factory(_owner(preferences), _connection),
        brightness: brightness,
        scale: scale,
      );
      await _open(tester);
      await _captureFrame(tester, '${brightness.name}-$scale-confirmed');
      await tester.tap(find.byKey(const ValueKey('profile-color-8')));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 10));
      await _open(tester);
      expect(_selected(tester, 'Lime'), isFalse);
      expect(_semantics(tester, 'Lime').properties.enabled, isFalse);
      expect(
        tester
            .widget<TextButton>(find.byKey(const ValueKey('profile-color-8')))
            .onPressed,
        isNull,
      );
      expect(
        tester
            .widget<ListTile>(
              find.byKey(const ValueKey('profile-color-automatic')),
            )
            .onTap,
        isNull,
      );
      await tester.ensureVisible(find.text('Reload colors'));
      await tester.pumpAndSettle();
      await _captureFrame(tester, '${brightness.name}-$scale-unverified');
      await tester.tap(find.text('Reload colors'));
      await tester.pumpAndSettle();
      expect(_selected(tester, 'Lime'), isTrue);
      expect(_semantics(tester, 'Lime').properties.enabled, isTrue);
      expect(
        tester
            .widget<TextButton>(find.byKey(const ValueKey('profile-color-8')))
            .onPressed,
        isNotNull,
      );
      expect(find.text('Reload colors'), findsNothing);
      await tester.ensureVisible(
        find.byKey(const ValueKey('profile-color-automatic')),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('profile-color-automatic')).hitTestable(),
        findsOneWidget,
      );
      await _captureFrame(tester, '${brightness.name}-$scale-repaired');
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('a held chooser cannot write to its replaced connection', (
    tester,
  ) async {
    final (preferences, storage) = await _preferences(initial: 3);
    final owner = _owner(preferences);
    var colors = _factory(owner, _connection);
    late StateSetter replace;
    await tester.pumpWidget(
      MaterialApp(
        theme: wingTheme(Brightness.light),
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              replace = setState;
              return _selector(colors);
            },
          ),
        ),
      ),
    );
    await _open(tester);
    replace(() => colors = _factory(owner, 'colour-owner-b'));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('profile-color-8')));
    await tester.pumpAndSettle();
    expect(storage.colourWrites, isEmpty);
    expect((await storage.getAll())['flutter.${_key(_connection)}'], 3);
  });

  testWidgets('a colour write waits behind the shared held reload', (
    tester,
  ) async {
    final (preferences, storage) = await _preferences(initial: 3);
    final owner = AppPreferences(preferences);
    addTearDown(owner.dispose);
    await _show(tester, _factory(owner, _connection));
    storage.holdNextReload = true;
    final reload = owner.reload();
    await tester.pump();
    expect(storage.reloadStarted.isCompleted, isTrue);
    try {
      await _open(tester);
      await tester.tap(find.byKey(const ValueKey('profile-color-8')));
      await tester.pump(const Duration(milliseconds: 400));
      expect(storage.colourWrites, isEmpty);
    } finally {
      storage.reloadRelease.complete();
      await tester.pump();
      await reload;
    }
    await tester.pumpAndSettle();
    expect((await storage.getAll())['flutter.${_key(_connection)}'], 8);
    await _open(tester);
    expect(_selected(tester, 'Blue'), isTrue);
  });
}

class _Storage extends InMemorySharedPreferencesStore {
  _Storage({
    required int initial,
    required this.rejectBlue,
    required this.rejectRestoration,
  }) : super.withData({'flutter.${_key(_connection)}': initial});

  final bool rejectBlue;
  final bool rejectRestoration;
  bool holdNextReload = false;
  final reloadStarted = Completer<void>();
  final reloadRelease = Completer<void>();
  final colourWrites = <(String, Object)>[];

  @override
  Future<bool> setValue(String valueType, String key, Object value) {
    if (key.startsWith('flutter.profile_color_v1_')) {
      colourWrites.add((key, value));
      if (rejectBlue && value == 8 || rejectRestoration && value == 3) {
        return Future.value(false);
      }
    }
    return super.setValue(valueType, key, value);
  }

  @override
  Future<Map<String, Object>> getAll() async {
    final snapshot = Map<String, Object>.of(await super.getAll());
    if (holdNextReload) {
      holdNextReload = false;
      reloadStarted.complete();
      await reloadRelease.future;
    }
    return snapshot;
  }
}
