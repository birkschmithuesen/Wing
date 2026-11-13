import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/services/scroll_capture_bridge.dart';
import 'package:wing/core/widgets/scroll_capture_viewport.dart';

Future<Object?> _native(String method, Map<String, Object> args) async {
  final response = Completer<Object?>();
  const channel = ScrollCaptureBridge.channel;
  await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .handlePlatformMessage(
        channel.name,
        channel.codec.encodeMethodCall(MethodCall(method, args)),
        (bytes) => response.complete(
          bytes == null ? null : channel.codec.decodeEnvelope(bytes),
        ),
      );
  return response.future;
}

void main() {
  testWidgets(
    'content changes keep native registration while capture reads fresh metrics',
    (tester) async {
      final registrations = <Map<Object?, Object?>>[];
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(ScrollCaptureBridge.channel, (
        call,
      ) async {
        if (call.method == 'register') {
          registrations.add(Map<Object?, Object?>.from(call.arguments as Map));
        }
        return null;
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(
          ScrollCaptureBridge.channel,
          null,
        ),
      );
      final controller = ScrollController();
      addTearDown(controller.dispose);
      var contentHeight = 2000.0;
      var footerHeight = 100.0;
      late StateSetter update;
      await tester.pumpWidget(
        MaterialApp(
          home: StatefulBuilder(
            builder: (context, setState) {
              update = setState;
              return Scaffold(
                body: Column(
                  children: [
                    Expanded(
                      child: ScrollCaptureViewport(
                        controller: controller,
                        onCaptureChanged: (_) {},
                        child: SingleChildScrollView(
                          controller: controller,
                          child: SizedBox(
                            height: contentHeight,
                            child: const Text('Growing answer'),
                          ),
                        ),
                      ),
                    ),
                    SizedBox(height: footerHeight),
                  ],
                ),
              );
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      final initialRegistrations = registrations.length;
      final id = registrations.last['id'] as int;
      final initial = await _native('metrics', {'id': id}) as Map;
      for (var delta = 0; delta < 20; delta++) {
        update(() => contentHeight += 50);
        await tester.pumpAndSettle();
        controller.jumpTo((delta + 1) * 10);
        await tester.pumpAndSettle();
      }
      final current = await _native('metrics', {'id': id}) as Map;
      expect(current['max'], greaterThan(initial['max'] as num));
      expect(
        current['offset'],
        controller.offset * tester.view.devicePixelRatio,
      );
      expect(
        registrations.length,
        initialRegistrations,
        reason:
            'Content growth and scroll offsets do not change the Android capture target',
      );

      update(() => footerHeight += 50);
      await tester.pumpAndSettle();
      expect(registrations.length, initialRegistrations + 1);
      final resized = await _native('metrics', {'id': id}) as Map;
      expect(resized['bottom'], lessThan(current['bottom'] as num));

      final other = ScrollCaptureBridge((_, _) async => null);
      await other.update({
        'left': 0.0,
        'top': 0.0,
        'right': 10.0,
        'bottom': 10.0,
      });
      final beforeReturn = registrations.length;
      update(() {});
      await tester.pumpAndSettle();
      expect(registrations.length, beforeReturn + 1);
      expect(registrations.last['id'], id);
      await other.dispose();
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    },
    variant: TargetPlatformVariant({TargetPlatform.android}),
  );

  for (final (reversed, centered) in [
    (false, false),
    (true, false),
    (false, true),
    (true, true),
  ]) {
    testWidgets(
      'capture scrolls only the viewport, clamps and restores reading reversed=$reversed centered=$centered',
      (tester) async {
        final registrations = <Map<Object?, Object?>>[];
        final methods = <String>[];
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        messenger.setMockMethodCallHandler(ScrollCaptureBridge.channel, (
          call,
        ) async {
          methods.add(call.method);
          if (call.method == 'register') {
            registrations.add(
              Map<Object?, Object?>.from(call.arguments as Map),
            );
          }
          return null;
        });
        addTearDown(
          () => messenger.setMockMethodCallHandler(
            ScrollCaptureBridge.channel,
            null,
          ),
        );
        final controller = ScrollController(initialScrollOffset: 200);
        addTearDown(controller.dispose);
        final states = <bool>[];
        const center = ValueKey('center');
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              appBar: AppBar(title: const Text('Group')),
              body: Column(
                children: [
                  Expanded(
                    child: ScrollCaptureViewport(
                      controller: controller,
                      onCaptureChanged: states.add,
                      child: centered
                          ? CustomScrollView(
                              controller: controller,
                              reverse: reversed,
                              center: center,
                              slivers: [
                                for (var side = 0; side < 2; side++)
                                  SliverFixedExtentList(
                                    key: side == 1 ? center : null,
                                    itemExtent: 80,
                                    delegate: SliverChildBuilderDelegate(
                                      (_, i) => Text('Message $side/$i'),
                                      childCount: 25,
                                    ),
                                  ),
                              ],
                            )
                          : ListView(
                              controller: controller,
                              reverse: reversed,
                              children: [
                                for (var i = 0; i < 50; i++)
                                  SizedBox(
                                    height: 80,
                                    child: Text('Message $i'),
                                  ),
                              ],
                            ),
                    ),
                  ),
                  const SizedBox(height: 100, child: Text('Composer')),
                ],
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final id = registrations.last['id'] as int;
        final metrics = await _native('metrics', {'id': id}) as Map;
        expect(
          metrics['offset'],
          reversed
              ? (controller.position.maxScrollExtent - 200) *
                    tester.view.devicePixelRatio
              : (200 - controller.position.minScrollExtent) *
                    tester.view.devicePixelRatio,
        );
        expect(
          metrics['max'],
          (controller.position.maxScrollExtent -
                  controller.position.minScrollExtent) *
              tester.view.devicePixelRatio,
        );
        if (centered) expect(controller.position.minScrollExtent, lessThan(0));
        expect(metrics['top'], greaterThan(0));
        expect(metrics['bottom'], lessThan(tester.view.physicalSize.height));
        expect(await _native('metrics', {'id': id + 1}), isNull);
        await _native('start', {'id': id});
        expect(states, [true]);
        final capture = _native('scroll', {'id': id, 'offset': 800});
        await tester.pump();
        await tester.pump();
        await tester.pump();
        expect((await capture as Map)['offset'], closeTo(800, .001));
        expect(
          controller.offset,
          reversed
              ? controller.position.maxScrollExtent -
                    800 / tester.view.devicePixelRatio
              : controller.position.minScrollExtent +
                    800 / tester.view.devicePixelRatio,
        );
        final clamped = _native('scroll', {'id': id, 'offset': -100});
        await tester.pump();
        await tester.pump();
        await tester.pump();
        expect((await clamped as Map)['offset'], 0);
        await _native('end', {'id': id});
        expect(controller.offset, 200);
        expect(states, [true, false]);
        await tester.pumpWidget(const SizedBox());
        await tester.pump();
        expect(methods.last, 'unregister');
        expect(tester.takeException(), isNull);
      },
      variant: TargetPlatformVariant({TargetPlatform.android}),
    );
  }
}
