import 'dart:async';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

class DashboardReadTimeout extends TimeoutException {
  DashboardReadTimeout(Duration timeout)
    : super(
        'The server took too long to respond. Check the connection and retry.',
        timeout,
      );

  @override
  String toString() => message!;
}

/// Bounds inactivity and aborts the actual HTTP operation when progress stops.
/// Authentication reads use this same transport before authenticated file reads.
class DashboardReadTransport {
  DashboardReadTransport(this.client, {required this.timeout});

  final http.Client client;
  final Duration timeout;
  final _pending = <Completer<void>>{};
  bool _closed = false;

  Future<http.Response> request(
    String method,
    Uri uri, {
    required Map<String, String> headers,
    String? body,
    int? maxBytes,
  }) async {
    if (_closed) throw http.RequestAbortedException(uri);
    final abort = Completer<void>();
    _pending.add(abort);
    void cancel() {
      if (!abort.isCompleted) abort.complete();
    }

    final request =
        http.AbortableRequest(method, uri, abortTrigger: abort.future)
          ..followRedirects = false
          ..headers.addAll(headers);
    if (body != null) request.body = body;
    final result = Completer<http.Response>();
    Timer? inactivity;
    void progress() {
      if (abort.isCompleted || result.isCompleted) return;
      inactivity?.cancel();
      inactivity = Timer(timeout, () {
        if (result.isCompleted) return;
        result.completeError(DashboardReadTimeout(timeout));
        cancel();
      });
    }

    progress();
    unawaited(
      _receive(request, abort, maxBytes, progress).then<void>(
        (response) {
          if (!result.isCompleted) result.complete(response);
        },
        onError: (Object error, StackTrace stack) {
          if (!result.isCompleted) result.completeError(error, stack);
        },
      ),
    );
    try {
      return await result.future;
    } finally {
      inactivity?.cancel();
      cancel();
      _pending.remove(abort);
    }
  }

  Future<http.Response> _receive(
    http.AbortableRequest request,
    Completer<void> abort,
    int? maxBytes,
    void Function() progress,
  ) async {
    final streamed = await client.send(request);
    progress();
    if (abort.isCompleted ||
        maxBytes != null &&
            streamed.contentLength != null &&
            streamed.contentLength! > maxBytes) {
      await streamed.stream.listen(null).cancel();
      if (abort.isCompleted) throw http.RequestAbortedException(request.url);
      throw const DashboardReadTooLarge();
    }
    final result = Completer<http.Response>();
    final bytes = BytesBuilder(copy: false);
    var received = 0;
    late final StreamSubscription<List<int>> subscription;
    subscription = streamed.stream.listen(
      (chunk) {
        if (result.isCompleted) return;
        received += chunk.length;
        if (maxBytes != null && received > maxBytes) {
          result.completeError(const DashboardReadTooLarge());
          unawaited(subscription.cancel());
        } else {
          if (chunk.isNotEmpty) progress();
          bytes.add(chunk);
        }
      },
      onError: (Object error, StackTrace stack) {
        if (!result.isCompleted) result.completeError(error, stack);
      },
      onDone: () {
        if (!result.isCompleted) {
          result.complete(
            http.Response.bytes(
              bytes.takeBytes(),
              streamed.statusCode,
              headers: streamed.headers,
              request: request,
              reasonPhrase: streamed.reasonPhrase,
            ),
          );
        }
      },
      cancelOnError: true,
    );
    unawaited(
      abort.future.then((_) async {
        if (!result.isCompleted) {
          result.completeError(http.RequestAbortedException(request.url));
        }
        await subscription.cancel();
      }),
    );
    return result.future;
  }

  void close() {
    _closed = true;
    for (final abort in _pending.toList()) {
      if (!abort.isCompleted) abort.complete();
    }
  }
}

class DashboardReadTooLarge implements Exception {
  const DashboardReadTooLarge();
}
