import 'package:wing/core/models/model_catalog.dart';
import 'package:wing/core/models/canonical_session.dart';
import 'package:uuid/uuid.dart';
import 'package:wing/core/services/connection_access.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/models/hermes_profile.dart';
import 'package:wing/core/services/profile_gateway.dart';

import 'support/existing_backend_login.dart';

/// Keeps a cancelled, dispatched warmup observed until it can be interrupted.
class LunaTurnCancellation {
  LunaTurnCancellation({
    required this.isTerminal,
    required this.interrupt,
    required this.cancelIdle,
  });

  final bool Function() isTerminal;
  final Future<void> Function() interrupt;
  final void Function() cancelIdle;
  bool finished = false;
  bool requested = false;
  bool active = false;
  bool _dispatchRequested = false;
  bool _accepted = false;
  bool _interruptSent = false;

  bool beginDispatch() {
    if (finished || isTerminal() || requested || _dispatchRequested) {
      return false;
    }
    _dispatchRequested = true;
    return true;
  }

  Future<void> turnStarted() async {
    active = true;
    if (requested) await request();
  }

  Future<void> dispatchAccepted() async {
    _accepted = true;
    if (requested) await request();
  }

  Future<void> request() async {
    if (finished || isTerminal() || _interruptSent) return;
    requested = true;
    if (active || _accepted) {
      _interruptSent = true;
      await interrupt();
    } else if (!_dispatchRequested) {
      cancelIdle();
    }
  }
}

/// Explicitly staged, opt-in QA against stock Hermes e5ea5fd9ccdf2913c0b21b24eb3d22b321d2e2a6.
/// PREPARE_WARMUP creates one empty Luna draft and sends one tiny Luna turn on
/// the same socket, making it discoverable in the phone's normal Chats list. OBSERVE
/// attaches to that exact chat and measures a turn sent through the phone UI.
/// No profile defaults, tool settings, config, existing chats, or cleanup change.
/// The manifest and metrics contain identity/timing only, never credentials or
/// transcript content. A submission attempt is journalled before sending and
/// cannot be retried by this harness, even after an uncertain response.
/// WING_PHONE_LUNA_WAIT_SECONDS bounds the turn/observer wait (default 180,
/// range 30–600). Expiry saves inconclusive metrics and retains the chat without
/// interrupting, deleting, or retrying its turn.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final environment = Platform.environment;
  final stage = environment['WING_PHONE_LUNA_STAGE'];

  test(
    'owned Luna chat preparation, warmup, or phone stream observation',
    () async {
      if (!{'PREPARE_WARMUP', 'OBSERVE'}.contains(stage)) {
        throw StateError('Choose PREPARE_WARMUP or OBSERVE explicitly.');
      }
      String requiredEnvironment(String name) {
        final value = environment[name];
        if (value == null || value.isEmpty) {
          throw StateError('Missing required runtime setting $name.');
        }
        return value;
      }

      final url = requiredEnvironment('WING_HERMES_URL');
      final loginFile = requiredEnvironment('WING_HERMES_LOGIN_FILE');
      final nonce = requiredEnvironment('WING_PHONE_LUNA_NONCE');
      if (!RegExp(r'^[a-zA-Z0-9_-]{8,80}$').hasMatch(nonce)) {
        throw StateError('Use an 8–80 character alphanumeric QA nonce.');
      }
      final profile = requiredEnvironment('WING_PHONE_LUNA_PROFILE');
      final waitSeconds = int.tryParse(
        environment['WING_PHONE_LUNA_WAIT_SECONDS'] ?? '180',
      );
      if (waitSeconds == null || waitSeconds < 30 || waitSeconds > 600) {
        throw StateError('WING_PHONE_LUNA_WAIT_SECONDS must be 30–600.');
      }
      final model = environment['WING_PHONE_LUNA_MODEL'] ?? 'gpt-5.6-luna';
      if (!RegExp(r'^gpt-[0-9]+\.[0-9]+-luna$').hasMatch(model)) {
        throw StateError('Only an exact advertised Luna model is permitted.');
      }
      final title = 'Wing Luna phone QA $nonce';
      final manifest = File('build/phone-performance/$nonce-session.json');
      final cancelFile = File(
        'build/phone-performance/$nonce-cancel.requested',
      );
      final metricsFile = File(
        'build/phone-performance/$nonce-${stage!.toLowerCase()}-metrics.json',
      );
      const owner = 'wing-phone-luna-performance-v1';
      late Map<String, dynamic> state;

      Future<void> saveState() async {
        await manifest.parent.create(recursive: true);
        await manifest.writeAsString(jsonEncode(state), flush: true);
      }

      if (stage == 'PREPARE_WARMUP') {
        if (await manifest.exists()) {
          throw StateError('This nonce already has a creation attempt.');
        }
        state = {
          'owner': owner,
          'nonce': nonce,
          'title': title,
          'url': url,
          'profile': profile,
          'model': model,
          'creation_attempted': false,
          'warmup_attempted': false,
          'warmup_completed': false,
        };
      } else {
        state = Map<String, dynamic>.from(
          jsonDecode(await manifest.readAsString()) as Map,
        );
        for (final entry in {
          'owner': owner,
          'nonce': nonce,
          'title': title,
          'url': url,
          'profile': profile,
          'model': model,
        }.entries) {
          if (state[entry.key] != entry.value) {
            throw StateError('QA manifest identity mismatch: ${entry.key}.');
          }
        }
        if (state['creation_verified'] != true) {
          throw StateError('The original creation was not verified.');
        }
      }
      if (await cancelFile.exists()) {
        throw StateError('This QA nonce has an interruption request.');
      }

      final previousOverrides = HttpOverrides.current;
      HttpOverrides.global = null;
      addTearDown(() => HttpOverrides.global = previousOverrides);
      final connection = await readExistingBackendConnection(
        url: url,
        loginFile: loginFile,
        id: owner,
      );
      final gateway = ProfileGateway.forConnection(
        ConnectionAccess(connection: connection, dashboardOAuth: null),
        WorkspaceScope(connectionId: connection.id, profileName: profile),
      );
      addTearDown(gateway.close);
      await gateway.requireProfile();
      final options = ModelCatalog.fromOptions(
        await gateway.read('model/options'),
      ).choices;
      final requestedProvider = environment['WING_PHONE_LUNA_PROVIDER'];
      final matches = options
          .where(
            (choice) =>
                choice.model == model &&
                (requestedProvider == null ||
                    choice.provider == requestedProvider),
          )
          .toList();
      if (matches.length != 1) {
        throw StateError(
          'Require exactly one advertised Luna route; provide its exact provider if ambiguous.',
        );
      }
      final provider = matches.single.provider;
      if (stage == 'OBSERVE' && state['provider'] != provider) {
        throw StateError('The advertised provider changed since preparation.');
      }
      await gateway.connect();

      void verifyInfo(Object? raw) {
        if (raw is! Map ||
            raw['model'] != model ||
            raw['provider'] != provider ||
            raw['profile_name'] != profile) {
          throw StateError(
            'Hermes did not confirm the owned Luna route/profile.',
          );
        }
      }

      if (stage == 'PREPARE_WARMUP') {
        state['provider'] = provider;
        state['creation_attempted'] = true;
        await saveState();
        final created = await gateway.call('session.create', {
          'request_id': const Uuid().v4(),
          'source': 'gui',
          'cwd_explicit': false,
          'title': title,
          'model': model,
          'provider': provider,
          'reasoning': 'low',
          'service_tier': 'normal',
        });
        if (!gateway.canonical.snapshot(created)) {
          throw StateError(
            'Creation did not return a current canonical snapshot.',
          );
        }
        state['runtime_id'] = created['session_id'];
        state['stored_id'] = created['stored_session_id'];
        await saveState();
        verifyInfo(created['info']);
        if (created['session_id'] is! String ||
            (created['session_id'] as String).isEmpty ||
            created['stored_session_id'] is! String ||
            (created['stored_session_id'] as String).isEmpty ||
            created['message_count'] != 0) {
          throw StateError('Hermes did not return one empty owned chat.');
        }
        final info = created['info'] as Map;
        state['cwd'] = info['cwd'];
        state['creation_verified'] = true;
        state['prepared_at_utc'] = DateTime.now().toUtc().toIso8601String();
        await saveState();
        // ignore: avoid_print
        print(
          'PHONE_LUNA_PREPARED ${jsonEncode({'title': title, 'model': model, 'provider': provider, 'manifest': manifest.path, 'generation_calls': 0})}',
        );
      }

      var runtime = state['runtime_id'];
      final stored = state['stored_id'];
      if (runtime is! String || stored is! String) {
        throw StateError('Missing original owned session identities.');
      }
      if (stage == 'OBSERVE') {
        if (state['warmup_completed'] != true) {
          throw StateError(
            'The owned chat needs its successful explicit warmup.',
          );
        }
        // Resume records the owner's current fences before observing the phone.
        final resumed = await gateway.resume(stored);
        verifyInfo(resumed['info']);
        final resumedRuntime = resumed['session_id'];
        if (resumedRuntime is! String ||
            resumedRuntime.isEmpty ||
            gateway.resumeDurableId(resumed) != stored) {
          throw StateError('Hermes did not confirm the owned durable QA chat.');
        }
        runtime = resumedRuntime;
        if (resumed['running'] == true) {
          throw StateError('Attach before the phone starts its measured turn.');
        }
      }
      final named = await gateway.call('session.info', {'session_id': runtime});
      if (named['title'] != title) {
        throw StateError(
          'The server did not confirm the exact owned QA title.',
        );
      }
      if (stage == 'PREPARE_WARMUP' && state['warmup_attempted'] == true) {
        throw StateError(
          'Warmup is exactly once and only on the empty QA chat.',
        );
      }

      final watch = Stopwatch()..start();
      final terminal = Completer<void>();
      terminal.future.ignore();
      var started = false;
      var chunks = 0;
      var characters = 0;
      var toolEvents = 0;
      int? firstChunkUs;
      int? turnStartedUs;
      String? terminalStatus;
      String? terminalType;
      final chunkTimesUs = <int>[];
      final eventCounts = <String, int>{};
      final numericUsage = <String, num>{};
      final readyAt = DateTime.now().toUtc().toIso8601String();

      final turnCancellation = LunaTurnCancellation(
        isTerminal: () => terminal.isCompleted,
        interrupt: () async {
          await gateway.call('session.interrupt', {'session_id': runtime});
        },
        cancelIdle: () {
          if (!terminal.isCompleted) {
            terminal.completeError(StateError('QA observation interrupted.'));
          }
        },
      );

      void cancellationFailed(Object error) {
        if (!turnCancellation.finished && !terminal.isCompleted) {
          terminal.completeError(error);
        }
      }

      gateway.onConnectionChanged = (connected) {
        if (!connected && !terminal.isCompleted) {
          terminal.completeError(
            StateError('QA socket disconnected; no retry.'),
          );
        }
      };
      gateway.onEvent = (event) {
        if (event.sessionId != runtime) return;
        if (!gateway.canonical.event(event)) {
          if (gateway.canonical.needsSnapshot(runtime as String) &&
              !terminal.isCompleted) {
            terminal.completeError(
              StateError(
                'QA observation needs a fresh owner snapshot; no automatic retry.',
              ),
            );
          }
          return;
        }
        if (event.type == 'session.info') {
          try {
            verifyInfo(event.data);
          } catch (error) {
            if (!terminal.isCompleted) terminal.completeError(error);
          }
        }
        if (event.type == 'message.start') {
          started = true;
          unawaited(
            turnCancellation.turnStarted().catchError(cancellationFailed),
          );
          turnStartedUs ??= watch.elapsedMicroseconds;
        }
        if (!started && (event.type == 'error' || event.type == 'turn.error')) {
          terminalType = event.type;
          if (!terminal.isCompleted) {
            terminal.completeError(StateError('The owned QA session failed.'));
          }
        }
        if (!started) return;
        eventCounts.update(event.type, (count) => count + 1, ifAbsent: () => 1);
        if (event.type == 'message.delta') {
          chunks++;
          final text = event.data['text'];
          if (text is String) characters += text.length;
          firstChunkUs ??= watch.elapsedMicroseconds;
          chunkTimesUs.add(watch.elapsedMicroseconds);
        }
        if (event.type.startsWith('tool.')) {
          toolEvents++;
          unawaited(turnCancellation.request().catchError(cancellationFailed));
        }
        final usage = event.data['usage'];
        if (usage is Map) {
          for (final key in const [
            'input',
            'output',
            'reasoning',
            'prompt',
            'completion',
            'total',
            'calls',
            'avg_latency_s',
            'avg_tps',
          ]) {
            final value = usage[key];
            if (value is num) numericUsage[key] = value;
          }
        }
        if (const {
              'message.complete',
              'error',
              'turn.end',
              'turn.error',
            }.contains(event.type) &&
            !terminal.isCompleted) {
          turnCancellation.active = false;
          terminalType = event.type;
          final status = event.data['status'];
          terminalStatus = status is String ? status : null;
          if (event.type == 'error' || event.type == 'turn.error') {
            terminal.completeError(StateError('The owned QA turn failed.'));
          } else {
            terminal.complete();
          }
        }
      };
      var checkingCancel = false;
      final cancellation = Timer.periodic(const Duration(milliseconds: 250), (
        _,
      ) {
        if (turnCancellation.finished ||
            checkingCancel ||
            terminal.isCompleted) {
          return;
        }
        checkingCancel = true;
        unawaited(() async {
          try {
            final requested = await cancelFile.exists();
            if (turnCancellation.finished || terminal.isCompleted) return;
            if (requested) await turnCancellation.request();
          } catch (error) {
            cancellationFailed(error);
          } finally {
            checkingCancel = false;
          }
        }());
      });
      addTearDown(cancellation.cancel);
      // ignore: avoid_print
      print(
        'PHONE_LUNA_READY ${jsonEncode({'stage': stage, 'title': title, 'ready_at_utc': readyAt, 'cancel_file': cancelFile.path, 'wait_seconds': waitSeconds})}',
      );
      Object? failure;
      var inconclusive = false;
      try {
        if (stage == 'PREPARE_WARMUP') {
          state['warmup_attempted'] = true;
          state['warmup_submission_id'] = const Uuid().v4();
          await saveState();
          if (await cancelFile.exists()) await turnCancellation.request();
          if (!turnCancellation.beginDispatch()) {
            throw StateError('QA warmup cancelled before dispatch.');
          }
          final accepted = await gateway.call('prompt.submit', {
            'session_id': runtime,
            'submission_id': state['warmup_submission_id'],
            'text':
                'Phone streaming QA warmup. Do not use tools or memories. '
                'Reply only: Luna phone QA ready.',
          });
          final receipt = CanonicalAdmission.fromJson(accepted);
          if (receipt.sessionId != runtime ||
              !const {
                'queued',
                'started',
                'terminal',
              }.contains(receipt.status)) {
            throw StateError(
              'Warmup did not return an owned admission receipt.',
            );
          }
          state['warmup_admission_id'] = receipt.id;
          await saveState();
          await turnCancellation.dispatchAccepted();
        }
        await terminal.future.timeout(Duration(seconds: waitSeconds));
        if (toolEvents != 0 || terminalStatus != 'complete') {
          throw StateError(
            'The QA turn did not complete cleanly without tools.',
          );
        }
        if (stage == 'PREPARE_WARMUP') {
          state['warmup_completed'] = true;
          await saveState();
        }
      } catch (error) {
        failure = error;
        inconclusive = error is TimeoutException;
      } finally {
        turnCancellation.finished = true;
        cancellation.cancel();
        gateway.onConnectionChanged = null;
        gateway.onEvent = null;
        watch.stop();
        final metrics = {
          'stage': stage,
          'owner': owner,
          'nonce': nonce,
          'model': model,
          'provider': provider,
          'ready_at_utc': readyAt,
          'finished_at_utc': DateTime.now().toUtc().toIso8601String(),
          'elapsed_us': watch.elapsedMicroseconds,
          'wait_seconds': waitSeconds,
          'turn_started_us': turnStartedUs,
          'first_chunk_us': firstChunkUs,
          'first_chunk_after_start_us':
              firstChunkUs == null || turnStartedUs == null
              ? null
              : firstChunkUs! - turnStartedUs!,
          'chunk_count': chunks,
          'character_count': characters,
          'chunk_times_us': chunkTimesUs,
          'event_counts': eventCounts,
          'tool_event_count': toolEvents,
          'terminal_type': terminalType,
          'terminal_status': terminalStatus,
          'usage': numericUsage,
          'interrupted': turnCancellation.requested,
          'inconclusive': inconclusive,
          'outcome': inconclusive
              ? 'inconclusive_timeout'
              : failure == null
              ? 'completed'
              : 'failed',
          'successful': failure == null,
        };
        await metricsFile.writeAsString(jsonEncode(metrics), flush: true);
        // ignore: avoid_print
        print(
          'PHONE_LUNA_METRICS ${jsonEncode({'path': metricsFile.path, 'chunk_count': chunks, 'terminal_status': terminalStatus, 'inconclusive': inconclusive, 'successful': failure == null})}',
        );
      }
      if (inconclusive) {
        throw StateError(
          'QA wait expired; metrics are inconclusive. The owned chat was retained '
          'without stopping or retrying its turn.',
        );
      }
      if (failure != null) {
        throw StateError('QA failed; inspect content-free metrics.');
      }
    },
    skip: stage == null,
    timeout: const Timeout(Duration(minutes: 15)),
  );
}
