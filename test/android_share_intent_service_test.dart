import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/services/android_share_intent_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel(AndroidShareIntentService.channelName);

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test(
    'native queue survives service disposal and advances in order',
    () async {
      final nativeQueue = <Map<String, Object?>>[
        {'id': 'share-1', 'text': 'First', 'files': const []},
        {
          'id': 'share-2',
          'text': 'Second',
          'target': {
            'connection': 'connection-a',
            'connection_identity': 'identity-a',
            'profile': 'work',
            'session': 'session-a',
          },
          'files': [
            {
              'path': '/cache/shared/photo.jpg',
              'name': 'photo.jpg',
              'mediaType': 'image/jpeg',
              'byteLength': 123,
            },
          ],
        },
      ];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (call.method == 'getPendingShare') {
              return nativeQueue.firstOrNull;
            }
            expect(call.method, 'acknowledgeShare');
            expect(call.arguments, {'id': nativeQueue.first['id']});
            nativeQueue.removeAt(0);
            return nativeQueue.firstOrNull;
          });

      final firstService = AndroidShareIntentService();
      await firstService.initialize();
      expect(firstService.pendingShare.value?.id, 'share-1');
      firstService.dispose();

      final replayedService = AndroidShareIntentService();
      addTearDown(replayedService.dispose);
      await replayedService.initialize();
      final first = replayedService.pendingShare.value!;
      expect(first.id, 'share-1');
      expect(await replayedService.acknowledgeShare(first), isTrue);
      final second = replayedService.pendingShare.value!;
      expect(second.id, 'share-2');
      expect(second.files.single.name, 'photo.jpg');
      expect(second.target?['session'], 'session-a');
      expect(await replayedService.acknowledgeShare(second), isTrue);
      expect(replayedService.pendingShare.value, isNull);
    },
  );

  test('failed native acknowledgement keeps the reviewed payload', () async {
    final native = {'id': 'share-1', 'text': 'Keep me', 'files': const []};
    var acknowledgeCalls = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'getPendingShare') {
            return native;
          }
          acknowledgeCalls += 1;
          if (acknowledgeCalls == 1) {
            throw PlatformException(code: 'write_failed');
          }
          return {
            'id': 'share-2',
            'text': 'Has an invalid file',
            'files': [
              {
                'path': '',
                'name': 'missing.jpg',
                'mediaType': 'image/jpeg',
                'byteLength': 10,
              },
            ],
          };
        });

    final service = AndroidShareIntentService();
    addTearDown(service.dispose);
    await service.initialize();
    final pending = service.pendingShare.value!;

    expect(await service.acknowledgeShare(pending), isFalse);
    expect(service.pendingShare.value, same(pending));
    expect(service.intakeError.value, isNull);
    expect(await service.acknowledgeShare(pending), isFalse);
    expect(service.pendingShare.value, same(pending));
  });

  test('warm duplicates cannot replace the item under review', () async {
    var acknowledgeCalls = 0;
    final first = {'id': 'share-1', 'text': 'First', 'files': const []};
    final second = {'id': 'share-2', 'text': 'Second', 'files': const []};
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'getPendingShare') {
            return first;
          }
          acknowledgeCalls += 1;
          return second;
        });
    final service = AndroidShareIntentService();
    addTearDown(service.dispose);
    await service.initialize();
    final reviewed = service.pendingShare.value!;

    await _sendPlatformCall(channel, MethodCall('sharePayload', first));
    await _sendPlatformCall(channel, MethodCall('sharePayload', second));
    expect(service.pendingShare.value, same(reviewed));

    const stale = AndroidSharePayload(id: 'share-2', text: 'Second');
    expect(await service.acknowledgeShare(stale), isFalse);
    expect(acknowledgeCalls, 0);
    expect(await service.acknowledgeShare(reviewed), isTrue);
    expect(service.pendingShare.value?.id, 'share-2');
    expect(await service.acknowledgeShare(reviewed), isFalse);
    expect(acknowledgeCalls, 1);
  });

  test('invalid intake and native share errors are exposed safely', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          channel,
          (_) async => {
            'id': 'share-1',
            'text': 'Do not keep only this text',
            'files': [
              {
                'path': '/cache/shared/incomplete.pdf',
                'name': '',
                'mediaType': 'application/pdf',
                'byteLength': 10,
              },
            ],
          },
        );
    final service = AndroidShareIntentService();
    addTearDown(service.dispose);
    await service.initialize();
    expect(service.pendingShare.value, isNull);
    expect(service.intakeError.value, 'Shared content could not be imported.');

    service.clearIntakeError();
    await _sendPlatformCall(
      channel,
      const MethodCall(
        'shareError',
        '  The shared file is no longer available.  ',
      ),
    );
    expect(
      service.intakeError.value,
      'The shared file is no longer available.',
    );
  });

  const target = {
    'connection': 'connection-a',
    'connection_identity': 'identity-a',
    'profile': 'work',
    'session': 'session-a',
  };

  test('camera launch sends the complete destination', () async {
    MethodCall? captured;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          captured = call;
          return null;
        });
    final service = AndroidShareIntentService();
    addTearDown(service.dispose);
    await service.capturePhoto(target);
    expect(captured?.method, 'capturePhoto');
    expect(captured?.arguments, {'target': target});
  });

  for (final field in target.keys) {
    test(
      'camera launch rejects a missing $field before calling native code',
      () async {
        var calls = 0;
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (_) async {
              calls++;
              return null;
            });
        final service = AndroidShareIntentService();
        addTearDown(service.dispose);
        await expectLater(
          service.capturePhoto({...target, field: ''}),
          throwsA(
            isA<StateError>().having(
              (error) => error.message,
              'message',
              'Camera destination is unavailable.',
            ),
          ),
        );
        expect(calls, 0);
      },
    );
  }

  test('native camera failure exposes only the safe message', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          channel,
          (_) => throw PlatformException(
            code: 'camera_busy',
            message: 'private native detail',
          ),
        );
    final service = AndroidShareIntentService();
    addTearDown(service.dispose);
    await expectLater(
      service.capturePhoto(target),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          'Camera could not be opened.',
        ),
      ),
    );
  });

  test(
    'group camera captures an exact room and rejects mixed destinations',
    () async {
      const target = {
        'connection': 'host',
        'connection_identity': 'instance-1',
        'room': 'room-1',
      };
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            expect(call.method, 'capturePhoto');
            expect(call.arguments, {'target': target});
            return null;
          });
      final service = AndroidShareIntentService();
      addTearDown(service.dispose);
      await service.capturePhoto(target);
      final payload = AndroidSharePayload.fromPlatform({
        'id': 'photo-1',
        'text': 'photo',
        'files': [],
        'target': target,
      });
      expect(payload!.target, target);
      await expectLater(
        service.capturePhoto({...target, 'profile': 'default'}),
        throwsStateError,
      );
    },
  );

  test(
    'incomplete target metadata preserves the share as untargeted content',
    () {
      final untargeted = AndroidSharePayload.fromPlatform({
        'id': 'share-3',
        'text': 'Keep this content',
        'files': const [],
        'target': {'connection': 'connection-a'},
      });
      expect(untargeted?.text, 'Keep this content');
      expect(untargeted?.target, isNull);
    },
  );
}

Future<void> _sendPlatformCall(MethodChannel channel, MethodCall call) {
  return TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .handlePlatformMessage(
        channel.name,
        channel.codec.encodeMethodCall(call),
        (_) {},
      );
}
