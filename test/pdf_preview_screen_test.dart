import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:wing/core/theme/wing_theme.dart';
import 'package:wing/core/services/server_connection_status.dart';
import 'package:wing/core/widgets/server_connection_label.dart';
import 'package:wing/core/widgets/studio_loading.dart';
import 'package:wing/core/widgets/wing_app_bar.dart';
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/screens/pdf_preview_screen.dart';
import 'package:wing/core/services/pdf_preview_service.dart';
import 'package:wing/core/services/remote_files_client.dart';

final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+j2ioAAAAASUVORK5CYII=',
);

class _PdfService extends PdfPreviewService {
  Future<PdfDocument> Function(Uint8List bytes)? opening;
  Future<Uint8List> Function(int page)? rendering;
  final rendered = <int>[];
  final closed = <String>[];
  final openedBytes = <Uint8List>[];

  @override
  Future<PdfDocument> open(Uint8List bytes) async {
    openedBytes.add(bytes);
    return opening == null
        ? const PdfDocument('doc', 2)
        : await opening!(bytes);
  }

  @override
  Future<Uint8List> render(PdfDocument document, int page) async {
    rendered.add(page);
    return rendering == null ? _png : await rendering!(page);
  }

  @override
  Future<void> close(PdfDocument document) async => closed.add(document.id);
}

Widget _app(
  _PdfService service,
  Future<RemoteFileDownload> Function() download,
) => MaterialApp(
  home: PdfPreviewScreen(
    title: 'Report.pdf',
    service: service,
    download: download,
  ),
);

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
        'PDF loading stays in instance row ${brightness.name} $scale',
        (tester) async {
          tester.view.physicalSize = Size(scale == 1 ? 390 : 320, 844);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          final status = ServerConnectionStatus('Claw')
            ..accessAvailable()
            ..liveChanged('fixture', true);
          addTearDown(status.dispose);
          final download = Completer<RemoteFileDownload>();
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
              home: ServerConnectionScope(
                status: status,
                child: PdfPreviewScreen(
                  title: 'Report.pdf',
                  service: _PdfService(),
                  download: () => download.future,
                ),
              ),
            ),
          );
          await tester.pump();
          final glyph = tester.getRect(find.byType(StudioLoading));
          final instance = tester.getRect(find.byType(ServerConnectionLabel));
          final header = tester.getRect(find.byType(WingAppBar));
          expect(glyph.center.dy, instance.center.dy);
          expect(glyph.left, greaterThanOrEqualTo(instance.right));
          expect(header.contains(glyph.topLeft), isTrue);
          if (capture) {
            await tester.runAsync(() async {
              final boundary =
                  frame.currentContext!.findRenderObject()!
                      as RenderRepaintBoundary;
              final image = await boundary.toImage();
              final bytes = await image.toByteData(
                format: ui.ImageByteFormat.png,
              );
              final directory = Directory(
                'build/design-previews/header-loading/site/native',
              )..createSync(recursive: true);
              await File(
                '${directory.path}/pdf-${brightness.name}-$scale-pending.png',
              ).writeAsBytes(bytes!.buffer.asUint8List());
              image.dispose();
            });
          }
          download.complete(
            RemoteFileDownload(filename: 'report.pdf', bytes: [1]),
          );
          await tester.pumpAndSettle();
          expect(find.byType(StudioLoading), findsNothing);
          expect(tester.getRect(find.byType(WingAppBar)), header);
          expect(tester.getRect(find.byType(ServerConnectionLabel)), instance);
          expect(find.text('Page 1 of 2'), findsOneWidget);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets('reads pages from one download and releases document on close', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final service = _PdfService();
    var downloads = 0;
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(2)),
          child: child!,
        ),
        home: PdfPreviewScreen(
          title: 'Report.pdf',
          service: service,
          download: () async {
            downloads++;
            return RemoteFileDownload(filename: 'report.pdf', bytes: [1, 2, 3]);
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Page 1 of 2'), findsOneWidget);
    expect(service.openedBytes.single, [1, 2, 3]);
    await tester.tap(find.byTooltip('Previous page'));
    await tester.pump();
    expect(service.rendered, [0]);
    await tester.tap(find.byTooltip('Next page'));
    await tester.pumpAndSettle();
    expect(find.text('Page 2 of 2'), findsOneWidget);
    expect(service.rendered, [0, 1]);
    expect(downloads, 1);
    await tester.tap(find.byTooltip('Next page'));
    await tester.pump();
    expect(service.rendered, [0, 1]);
    expect(find.byType(InteractiveViewer), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(service.closed, ['doc']);
  });

  testWidgets('closing during download never creates a native document', (
    tester,
  ) async {
    final service = _PdfService();
    final download = Completer<RemoteFileDownload>();
    await tester.pumpWidget(_app(service, () => download.future));
    await tester.pumpWidget(const SizedBox.shrink());
    download.complete(RemoteFileDownload(filename: 'report.pdf', bytes: [1]));
    await tester.pump();
    expect(service.openedBytes, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('closing during native open releases its late handle', (
    tester,
  ) async {
    final open = Completer<PdfDocument>();
    final service = _PdfService()..opening = (_) => open.future;
    await tester.pumpWidget(
      _app(
        service,
        () async => RemoteFileDownload(filename: 'report.pdf', bytes: [1]),
      ),
    );
    await tester.pump();
    expect(service.openedBytes, hasLength(1));
    await tester.pumpWidget(const SizedBox.shrink());
    open.complete(const PdfDocument('late', 2));
    await tester.pump();
    expect(service.closed, ['late']);
    expect(service.rendered, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('page failure retries without another download or native open', (
    tester,
  ) async {
    var fail = true;
    final service = _PdfService()
      ..rendering = (_) async {
        if (fail) throw StateError('PRIVATE DOCUMENT DETAIL');
        return _png;
      };
    var downloads = 0;
    await tester.pumpWidget(
      _app(service, () async {
        downloads++;
        return RemoteFileDownload(filename: 'report.pdf', bytes: [1]);
      }),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('could not be displayed'), findsOneWidget);
    expect(find.textContaining('PRIVATE'), findsNothing);
    fail = false;
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(find.byType(InteractiveViewer), findsOneWidget);
    expect(service.openedBytes, hasLength(1));
    expect(downloads, 1);
    expect(service.rendered, [0, 0]);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'closing during render releases only after the native decode settles',
    (tester) async {
      final rendering = Completer<Uint8List>();
      final entered = Completer<void>();
      final service = _PdfService()
        ..rendering = (_) {
          entered.complete();
          return rendering.future;
        };
      await tester.pumpWidget(
        _app(
          service,
          () async => RemoteFileDownload(filename: 'report.pdf', bytes: [1]),
        ),
      );
      await tester.pump();
      await entered.future;
      await tester.pumpWidget(const SizedBox.shrink());
      expect(service.closed, isEmpty);
      rendering.complete(_png);
      await tester.pump();
      expect(service.closed, ['doc']);
      expect(tester.takeException(), isNull);
    },
  );
}
