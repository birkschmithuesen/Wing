import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/services/pdf_preview_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('pdf-test');
  const service = PdfPreviewService(channel: channel);
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test(
    'opens exact bytes and addresses pages and disposal by native handle',
    () async {
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return switch (call.method) {
          'open' => {'documentId': 'opaque-1', 'pageCount': 2},
          'render' => Uint8List.fromList([1, 2, 3]),
          _ => null,
        };
      });
      final bytes = Uint8List.fromList([37, 80, 68, 70]);
      final document = await service.open(bytes);
      expect(calls.single.arguments, {'bytes': bytes});
      expect(document.pageCount, 2);
      expect(await service.render(document, 1), [1, 2, 3]);
      expect(calls.last.arguments, {'documentId': 'opaque-1', 'page': 1});
      await service.close(document);
      expect(calls.last.arguments, {'documentId': 'opaque-1'});
    },
  );

  test('invalid metadata releases the returned native document', () async {
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return call.method == 'open'
          ? {'documentId': 'bad-document', 'pageCount': 0}
          : null;
    });
    await expectLater(service.open(Uint8List.fromList([1])), throwsStateError);
    expect(calls.map((call) => call.method), ['open', 'close']);
    expect(calls.last.arguments, {'documentId': 'bad-document'});
  });

  test('empty PDF bytes are rejected before invoking the platform', () async {
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return null;
    });
    await expectLater(service.open(Uint8List(0)), throwsStateError);
    expect(calls, isEmpty);
  });

  for (final page in [-1, 2]) {
    test(
      'page $page outside the document never invokes the platform',
      () async {
        final calls = <MethodCall>[];
        messenger.setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return null;
        });
        await expectLater(
          service.render(const PdfDocument('document', 2), page),
          throwsArgumentError,
        );
        expect(calls, isEmpty);
      },
    );
  }

  for (final error in [
    PlatformException(code: 'decoder', message: '/private/document.pdf SECRET'),
    MissingPluginException('PDF support unavailable'),
  ]) {
    test('open hides native ${error.runtimeType} details', () async {
      messenger.setMockMethodCallHandler(channel, (_) async => throw error);
      await expectLater(
        service.open(Uint8List.fromList([1])),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'safe error',
            'This PDF could not be displayed.',
          ),
        ),
      );
    });

    test('render hides native ${error.runtimeType} details', () async {
      messenger.setMockMethodCallHandler(channel, (_) async => throw error);
      await expectLater(
        service.render(const PdfDocument('document', 1), 0),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'safe error',
            'This PDF page could not be displayed.',
          ),
        ),
      );
    });

    test(
      'close tolerates native ${error.runtimeType} after departure',
      () async {
        messenger.setMockMethodCallHandler(channel, (_) async => throw error);
        await expectLater(
          service.close(const PdfDocument('gone', 1)),
          completes,
        );
      },
    );
  }

  for (final image in [null, Uint8List(0)]) {
    test(
      'render rejects ${image == null ? 'missing' : 'empty'} page data',
      () async {
        messenger.setMockMethodCallHandler(channel, (_) async => image);
        await expectLater(
          service.render(const PdfDocument('document', 1), 0),
          throwsStateError,
        );
      },
    );
  }
}
