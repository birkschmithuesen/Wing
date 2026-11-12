import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:wing/core/models/connection.dart';
import 'package:wing/core/services/server_connection_status.dart';
import 'package:wing/core/widgets/server_connection_label.dart';
import 'package:wing/core/widgets/studio_loading.dart';
import 'package:wing/core/widgets/wing_app_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wing/core/models/hermes_profile.dart';
import 'package:wing/core/models/profile_colors.dart';
import 'package:wing/core/services/profile_colors_session.dart';
import 'package:wing/core/services/app_preferences.dart';
import 'package:wing/core/theme/wing_theme.dart';
import 'package:wing/core/theme/profile_colors.dart';
import 'package:wing/core/widgets/chat_profile_bar.dart';

void main() {
  const capture = bool.fromEnvironment('CAPTURE_HEADER_LOADING');
  setUpAll(() async {
    if (!capture) return;
    for (final entry in {
      'Roboto': 'build/studio-roboto.ttf',
      'MaterialIcons': 'build/studio-icons.otf',
    }.entries) {
      await (FontLoader(entry.key)..addFont(
            File(entry.value).readAsBytes().then(ByteData.sublistView),
          ))
          .load();
    }
  });
  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      testWidgets(
        'five profiles keep a clear header progress slot ${brightness.name} $scale',
        (tester) async {
          SharedPreferences.setMockInitialValues({});
          final preferences = AppPreferences(
            await SharedPreferences.getInstance(),
          );
          addTearDown(preferences.dispose);
          final status = ServerConnectionStatus('Claw')
            ..accessAvailable()
            ..liveChanged('fixture', true);
          addTearDown(status.dispose);
          tester.view.physicalSize = Size(scale == 1 ? 390 : 320, 844);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          var pending = true;
          late StateSetter change;
          final frame = GlobalKey();
          await tester.pumpWidget(
            MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: wingTheme(brightness),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: TextScaler.linear(scale)),
                child: RepaintBoundary(key: frame, child: child!),
              ),
              home: StatefulBuilder(
                builder: (context, setState) {
                  change = setState;
                  return Scaffold(
                    appBar: WingAppBar(
                      context: context,
                      title: const Text('Chats'),
                      contextRow: Row(
                        children: [
                          SizedBox(
                            width: 104,
                            child: ServerConnectionLabel(
                              label: 'Claw',
                              icon: ConnectionIcon.home,
                              status: status,
                              style: TextStyle(
                                fontSize: 12,
                                color: WingTokens.of(context).muted,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: ChatProfileBar(
                              profiles: const [
                                HermesProfile(name: 'default', isDefault: true),
                                HermesProfile(name: 'butler'),
                                HermesProfile(name: 'claw'),
                                HermesProfile(name: 'mira'),
                                HermesProfile(name: 'pace'),
                              ],
                              selectedProfiles: const {'default'},
                              createColors: () => ProfileColorsSession(
                                preferences: preferences,
                                connectionIdentity: 'fixture',
                              ),
                              onSelected: (_) {},
                              onOpenBotChat: (_) {},
                            ),
                          ),
                          const SizedBox(width: 16),
                        ],
                      ),
                    ),
                    body: StudioPageLoading(
                      active: pending,
                      label: 'Loading chats',
                      child: const Padding(
                        padding: EdgeInsets.fromLTRB(16, 4, 16, 4),
                        child: TextField(
                          decoration: InputDecoration(
                            hintText: 'Search chats',
                            prefixIcon: Icon(Icons.search),
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          );
          await tester.pump();
          final pulse = find.byType(StudioLoading);
          expect(pulse, findsOneWidget);
          final search = tester.getRect(find.byType(TextField));
          final slot = tester.getRect(
            find.byKey(const ValueKey('studio-loading-slot')),
          );
          final glyph = tester.getRect(pulse);
          final profiles = {
            for (final name in ['default', 'butler', 'claw', 'mira', 'pace'])
              name: tester.getRect(find.byKey(ValueKey('chat-profile-$name'))),
          };
          expect(glyph.overlaps(search), isFalse);
          expect(
            glyph.center.dy,
            closeTo(
              tester.getRect(find.byType(ServerConnectionLabel)).center.dy,
              1,
            ),
          );
          for (final box in profiles.values) {
            expect(box.overlaps(glyph), isFalse);
            expect(box.right, lessThanOrEqualTo(slot.left));
          }
          for (final phase in ['pending', 'ready']) {
            change(() => pending = phase == 'pending');
            await tester.pump();
            await tester.pump();
            expect(
              find.byType(StudioLoading),
              pending ? findsOneWidget : findsNothing,
            );
            expect(tester.getRect(find.byType(TextField)), search);
            expect(
              tester.getRect(find.byKey(const ValueKey('studio-loading-slot'))),
              slot,
            );
            for (final entry in profiles.entries) {
              expect(
                tester.getRect(
                  find.byKey(ValueKey('chat-profile-${entry.key}')),
                ),
                entry.value,
              );
            }
            expect(tester.takeException(), isNull);
            if (capture) {
              await tester.runAsync(() async {
                final image =
                    await (frame.currentContext!.findRenderObject()!
                            as RenderRepaintBoundary)
                        .toImage();
                final bytes = await image.toByteData(
                  format: ui.ImageByteFormat.png,
                );
                final file = File(
                  'build/design-previews/header-loading/site/native/five-profiles-${brightness.name}-$scale-$phase.png',
                );
                file.parent.createSync(recursive: true);
                await file.writeAsBytes(bytes!.buffer.asUint8List());
                image.dispose();
              });
            }
          }
        },
      );
    }
  }

  testWidgets('chat profile bar uses the saved administration color', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    final owner = AppPreferences(preferences);
    addTearDown(owner.dispose);
    final colors = ProfileColorsSession(
      preferences: owner,
      connectionIdentity: 'connection-a',
    )..updateProfiles(['work']);
    final picker = colors.beginChoice('work')!;
    await picker.choose(ProfileColorChoice.blue);
    picker.dispose();
    colors.dispose();
    await tester.pumpWidget(
      MaterialApp(
        theme: wingTheme(Brightness.dark),
        home: Scaffold(
          body: ChatProfileBar(
            onOpenBotChat: (_) {},
            profiles: const [HermesProfile(name: 'work')],
            selectedProfiles: const {},
            createColors: () => ProfileColorsSession(
              preferences: owner,
              connectionIdentity: 'connection-a',
            ),
            onSelected: (_) {},
          ),
        ),
      ),
    );
    final box = tester.widget<Container>(
      find.descendant(
        of: find.byKey(const ValueKey('chat-profile-work')),
        matching: find.byType(Container),
      ),
    );
    expect(
      (box.decoration! as BoxDecoration).color,
      desktopProfileSwatches[8].withValues(alpha: .22),
    );
  });

  test('profile colors match desktop, including unsigned hash overflow', () {
    expect(desktopProfileColor('default'), isNull);
    for (final (name, hue) in [
      ('work', 1.0),
      ('personal', 264.0),
      ('memory-maintenance', 255.0),
    ]) {
      expect(
        desktopProfileColor(name),
        HSLColor.fromAHSL(1, hue, .68, .58).toColor(),
      );
    }
  });

  testWidgets(
    'scrolling profile choices preserves selection when opening Bot chat',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final owner = AppPreferences(await SharedPreferences.getInstance());
      addTearDown(owner.dispose);
      ProfileColorsSession createColors() => ProfileColorsSession(
        preferences: owner,
        connectionIdentity: 'connection-a',
      );
      final semantics = tester.ensureSemantics();
      String? selected;
      final opened = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          theme: wingTheme(Brightness.dark),
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 144,
                child: StatefulBuilder(
                  builder: (context, setState) => ChatProfileBar(
                    onOpenBotChat: opened.add,
                    createColors: createColors,
                    profiles: [
                      for (var i = 0; i < 12; i++)
                        HermesProfile(
                          name: 'profile-${i.toString().padLeft(2, '0')}',
                        ),
                      const HermesProfile(name: 'aaa'),
                      const HermesProfile(
                        name: 'default',
                        displayName: 'Zebra',
                        isDefault: true,
                      ),
                    ],
                    selectedProfiles: {if (selected != null) selected!},
                    onSelected: (name) => setState(() => selected = name),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      final bar = find.byKey(const ValueKey('chat-profile-scroll'));
      final last = find.byKey(const ValueKey('chat-profile-profile-11'));
      final barBounds = tester.getRect(bar);
      expect(barBounds.height, greaterThanOrEqualTo(48));
      expect(
        tester
            .getTopLeft(find.byKey(const ValueKey('chat-profile-default')))
            .dx,
        lessThan(
          tester.getTopLeft(find.byKey(const ValueKey('chat-profile-aaa'))).dx,
        ),
      );
      expect(
        find.byKey(const ValueKey('chat-profile-default')).hitTestable(),
        findsOneWidget,
      );
      expect(last.hitTestable(), findsNothing);
      await tester.drag(bar, const Offset(-600, 0));
      await tester.pumpAndSettle();
      await tester.tap(last);
      await tester.pumpAndSettle();
      expect(selected, 'profile-11');
      expect(
        tester.getSemantics(find.bySemanticsLabel('profile-11')),
        matchesSemantics(
          label: 'profile-11',
          hint: 'Clear profile filter. Long press to open Bot chat',
          isButton: true,
          isSelected: true,
          hasSelectedState: true,
          hasTapAction: true,
          hasLongPressAction: true,
        ),
      );
      await tester.longPress(last);
      await tester.pumpAndSettle();
      expect(opened, ['profile-11']);
      expect(selected, 'profile-11');
      await tester.drag(bar, const Offset(600, 0));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('chat-profile-profile-00')).hitTestable(),
        findsOneWidget,
      );
      expect(tester.getRect(bar), barBounds);
      final home = find.byKey(const ValueKey('chat-profile-default'));
      expect(
        find.descendant(of: home, matching: find.byIcon(Icons.home_outlined)),
        findsOneWidget,
      );
      await tester.longPress(home);
      await tester.pumpAndSettle();
      expect(opened, ['profile-11', 'default']);
      expect(selected, 'profile-11');
      semantics.dispose();
    },
  );
}
