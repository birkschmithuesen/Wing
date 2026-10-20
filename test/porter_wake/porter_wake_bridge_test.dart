import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wing/porter_wake/porter_wake_bridge.dart';
import 'package:wing/porter_wake/porter_wake_presentation.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final calls = <MethodCall>[];
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  setUp(() {
    calls.clear();
    messenger.setMockMethodCallHandler(MethodChannelPorterWakeBridge.channel, (call) async {
      calls.add(call);
      return switch (call.method) {
        'initialize' => [
          {'type': 'endpoint', 'connection': 'c1', 'url': 'http://100.75.24.33:2586/upAbC123xyz?up=1'},
        ],
        'register' => true,
        'deviceLabel' => 'Pixel 7',
        _ => null,
      };
    });
  });

  test('start initializes with the role and replays queued events', () async {
    final events = <PorterBridgeEvent>[];
    await MethodChannelPorterWakeBridge().start((e) async {
      events.add(e);
      return true;
    }, background: false);
    expect(calls.first.method, 'initialize');
    expect(calls.first.arguments, {'role': 'main'});
    expect((events.single as PorterEndpointEvent).url, endsWith('?up=1'));
  });

  test('show sends the spec map; register sends the connection id', () async {
    final bridge = MethodChannelPorterWakeBridge();
    await bridge.show(PorterNotificationSpec.neutral('c1', 'n-3f2a9c1b7d4e'));
    expect(await bridge.register('c1'), isTrue);
    expect(calls[0].method, 'show');
    expect((calls[0].arguments as Map)['id'], 214700);
    expect(calls[1].method, 'register');
    expect(calls[1].arguments, 'c1');
  });

  test('an incoming event of an unknown type is answered false', () async {
    await MethodChannelPorterWakeBridge().start((_) async => true, background: true);
    final reply = await messenger.handlePlatformMessage(
      MethodChannelPorterWakeBridge.channel.name,
      const StandardMethodCodec().encodeMethodCall(
        const MethodCall('event', {'type': 'teleport', 'connection': 'c1'})),
      null,
    );
    expect(const StandardMethodCodec().decodeEnvelope(reply!), isFalse);
  });
}
