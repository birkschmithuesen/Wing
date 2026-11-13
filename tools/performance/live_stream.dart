import 'package:wing/core/models/model_catalog.dart';
import 'package:wing/core/models/profile_session_key.dart';
// Profile-only full-app observer. Mutations target explicitly named QA chats,
// created here or manually created and adopted after selecting Luna.
// flutter build apk --profile --dart-define=WING_PERF_INSTRUMENTATION=true -t tools/performance/live_stream.dart
// No credentials, addresses, profile names or transcript text leave this tool.
// Stop a capture before native navigation. After reopening Wing, adopt the
// selected QA chat again; retained slots do not own replacement controllers.
import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:ui' show FramePhase, FrameTiming;

import 'package:flutter/foundation.dart';
import 'package:wing/core/services/performance_instrumentation.dart';
import 'package:flutter/material.dart';
import 'package:wing/core/models/answer_versions.dart';
import 'package:wing/core/screens/profile_workspace_screen.dart';
import 'package:wing/core/services/profile_workspace_controller.dart';
import 'package:wing/core/services/completion_diagnostics.dart';
import 'package:wing/core/widgets/background_markdown_content.dart';
import 'package:wing/core/widgets/markdown_message_content.dart';
import 'package:wing/main.dart' as app;

const _prompts = {
  'prose':
      'Wing performance QA. Do not use tools, memories, files or delegation. '
      'Write about 1200 words of ordinary prose describing an imaginary garden. '
      'Use twenty paragraphs. Include italic and bold phrases and occasional '
      'technical identifiers such as garden_path_index. No code blocks. '
      'Finish with the exact sentence: Wing prose QA complete.',
  'mixed':
      'Wing performance QA. Do not use tools, memories, files or delegation. '
      'Write about 1200 words explaining an imaginary garden planner. Include '
      'headings, paragraphs, nested lists, a small Markdown table, ordinary '
      'links to https://example.com and six fenced Dart code examples. '
      'Finish with the exact sentence: Wing mixed QA complete.',
  'workflow':
      'Review this Flutter design without tools, files, memories or delegation: '
      'a workspace owner coordinates chat I/O, a composer owns unsent drafts, '
      'a reading owner exposes immutable history, and widgets render observations '
      'and forward commands. Give a practical change plan for adding a model '
      'picker while preserving these boundaries. Use about 500 words, headings, '
      'a responsibility table and two short Dart examples. Explain how to keep '
      'a late settings read from overwriting a reconnected chat and how to protect '
      'the change with one focused regression. '
      'Finish with the exact sentence: Wing workflow QA complete.',
};

Iterable<Element> _walk(Element element) sync* {
  if (element.widget case Offstage(offstage: true)) return;
  yield element;
  final children = <Element>[];
  element.visitChildren(children.add);
  for (final child in children) {
    yield* _walk(child);
  }
}

ProfileWorkspaceController _controller() {
  final root = WidgetsBinding.instance.rootElement;
  if (root == null) throw StateError('Not mounted');
  return _walk(
    root,
  ).map((e) => e.widget).whereType<ProfileWorkspaceScreen>().single.controller;
}

ProfileChat? _visibleChat(ProfileWorkspaceController controller) =>
    controller.notificationChat ?? controller.current?.chat;

List<double>? _composerBounds() {
  final root = WidgetsBinding.instance.rootElement;
  if (root == null) return null;
  for (final element in _walk(root)) {
    if (element.widget.key != const Key('profile-message-composer')) continue;
    final box = element.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return null;
    final origin = box.localToGlobal(Offset.zero);
    final ratio = View.of(element).devicePixelRatio;
    return [
      origin.dx * ratio,
      origin.dy * ratio,
      box.size.width * ratio,
      box.size.height * ratio,
    ];
  }
  return null;
}

class _Owned {
  _Owned(this.controller, this.chat);
  final ProfileWorkspaceController controller;
  final ProfileChat chat;
  bool dispatching = false;
  bool dispatchFailed = false;
  int submissions = 0;
  String? preservedDraft;
  String? mode;
  int responseBaseCount = 0;

  String? get finalResponse {
    for (
      var i = chat.reading.messages.length - 1;
      i >= responseBaseCount;
      i--
    ) {
      if (chat.reading.messages[i]['role'] == 'assistant') {
        return answerMessageText(chat.reading.messages[i]);
      }
    }
    return null;
  }

  String get sentinel => switch (mode) {
    'prose' => 'Wing prose QA complete.',
    'mixed' => 'Wing mixed QA complete.',
    'workflow' => 'Wing workflow QA complete.',
    _ => throw StateError('Stage an owned QA workload first'),
  };
}

bool _isSelected(_Owned item) {
  try {
    return identical(_controller(), item.controller) &&
        identical(_visibleChat(item.controller), item.chat);
  } catch (_) {
    return false;
  }
}

class _Measurement {
  _Measurement(this.owned) {
    timer = Timer.periodic(const Duration(milliseconds: 20), (_) => sample());
  }
  final _Owned owned;
  final startUs = developer.Timeline.now;
  late final Timer timer;
  final samples = <Map<String, Object?>>[];
  final frames = <Map<String, int>>[];
  int sourceChanges = 0, previousLength = 0, maximumLength = 0;
  int? firstTextUs, firstReadyUs, completedUs;
  int renderedCharacters = 0, pendingParses = 0;
  bool renderReady = false;
  bool finalSentinelMounted = false, latestResponseMounted = false;
  int? latestSourceObservedUs, latestReadyLagUs, finalReadyUs;
  int? _lastReadySourceObservedUs;
  int _lastRenderSample = 0;

  void sample() {
    final now = developer.Timeline.now;
    final chat = owned.chat;
    final length = chat.reading.streaming.length;
    if (length != previousLength) {
      sourceChanges++;
      previousLength = length;
      if (length > maximumLength) maximumLength = length;
      if (length > 0) firstTextUs ??= now;
      if (length > 0) latestSourceObservedUs = now;
    }
    if (!chat.runtime.blocksTurnAdmission && maximumLength > 0) {
      completedUs ??= now;
    }
    if (now - _lastRenderSample < 100000) return;
    _lastRenderSample = now;
    renderedCharacters = 0;
    pendingParses = 0;
    renderReady = false;
    finalSentinelMounted = false;
    latestResponseMounted = false;
    final root = WidgetsBinding.instance.rootElement;
    final selected = _isSelected(owned);
    if (root != null && maximumLength > 0 && selected) {
      final source = chat.reading.streaming.isNotEmpty
          ? chat.reading.streaming
          : owned.finalResponse;
      final bodies = _walk(root).where(
        (e) =>
            e.widget is MarkdownMessageContent &&
            (e.widget as MarkdownMessageContent).data == source,
      );
      var allReady = true;
      for (final body in bodies) {
        latestResponseMounted = true;
        final states = _walk(body)
            .whereType<StatefulElement>()
            .map((e) => e.state)
            .whereType<BackgroundMarkdownContentState>()
            .toList();
        renderedCharacters += states.fold<int>(
          0,
          (n, s) => n + (s.renderedSource?.length ?? 0),
        );
        pendingParses += states.where((s) => s.pending).length;
        allReady =
            allReady &&
            states.every(
              (s) => !s.pending && s.renderedSource == s.widget.data,
            );
        if (renderedCharacters > 0) firstReadyUs ??= now;
        finalSentinelMounted =
            finalSentinelMounted ||
            _walk(body).any(
              (e) =>
                  e.widget is RichText &&
                  (e.widget as RichText).text.toPlainText().contains(
                    owned.sentinel,
                  ),
            );
      }
      renderReady = latestResponseMounted && allReady;
      if (renderReady &&
          latestSourceObservedUs != null &&
          _lastReadySourceObservedUs != latestSourceObservedUs) {
        latestReadyLagUs = now - latestSourceObservedUs!;
        _lastReadySourceObservedUs = latestSourceObservedUs;
      }
      if (!chat.runtime.blocksTurnAdmission &&
          renderReady &&
          owned.finalResponse != null) {
        finalReadyUs ??= now;
      }
    }
    samples.add({
      'timeUs': now,
      'sourceCharacters': length,
      'renderedProseCharacters': renderedCharacters,
      'pendingParses': pendingParses,
      'renderReady': renderReady,
      'draftCharacters': chat.composer.observation.displayedText.length,
      'selected': selected,
      'busy': chat.runtime.blocksTurnAdmission,
      'latestResponseMounted': latestResponseMounted,
    });
  }

  void timings(List<FrameTiming> timings) {
    for (final frame in timings) {
      final start = frame.timestampInMicroseconds(FramePhase.buildStart);
      if (start >= startUs) {
        frames.add({
          'startUs': start,
          'buildUs': frame.buildDuration.inMicroseconds,
          'rasterUs': frame.rasterDuration.inMicroseconds,
        });
      }
    }
  }

  Map<String, Object?> report() => {
    'startUs': startUs,
    'endUs': developer.Timeline.now,
    'sourcePollIntervalUs': 20000,
    'renderPollIntervalUs': 100000,
    'observedSourceChanges': sourceChanges,
    'maximumSourceCharacters': maximumLength,
    'firstObservedTextUs': firstTextUs,
    'firstObservedReadyUs': firstReadyUs,
    'firstTextToReadyObservedUs': firstTextUs == null || firstReadyUs == null
        ? null
        : firstReadyUs! - firstTextUs!,
    'firstObservedCompletionUs': completedUs,
    'latestSourceToReadyObservedUs': latestReadyLagUs,
    'completionToReadyObservedUs': completedUs == null || finalReadyUs == null
        ? null
        : finalReadyUs! - completedUs!,
    'finalSentinelMounted': finalSentinelMounted,
    'samples': samples,
    'frames': frames,
  };
}

void main() {
  if (!PerformanceInstrumentation.enabled) {
    throw StateError(
      'Build with --dart-define=WING_PERF_INSTRUMENTATION=true.',
    );
  }
  if (!kProfileMode) throw StateError('Use an AOT profile build');
  WidgetsFlutterBinding.ensureInitialized();
  final owned = <_Owned>[];
  _Measurement? measurement;
  var mutating = false;
  _Owned selected(Map<String, String> parameters) {
    final slot = int.tryParse(parameters['slot'] ?? '');
    if (slot == null || slot < 0 || slot >= owned.length) {
      throw StateError('Unknown owned slot');
    }
    return owned[slot];
  }

  Map<String, Object?> snapshot(_Owned item) {
    final selected = _isSelected(item);
    return {
      'selected': selected,
      'luna': RegExp(r'^gpt-\d+\.\d+-luna$').hasMatch(item.chat.model ?? ''),
      'reasoningEffort': item.chat.reasoningEffort,
      'busy': item.chat.runtime.blocksTurnAdmission,
      'status': item.chat.runtime.execution.name,
      'sourceCharacters': item.chat.reading.streaming.length,
      'savedMessages': item.chat.reading.messages.length,
      'draftCharacters': item.chat.composer.observation.displayedText.length,
      'draftPreserved': item.preservedDraft == null
          ? null
          : item.preservedDraft == item.chat.composer.observation.displayedText,
      'chatError': item.chat.runtime.error != null,
      'controllerError': item.controller.error != null,
      'toolActivityCount': item.chat.runtime.toolActivities.length,
      'subagentCount': item.chat.subagents.length,
      'composerBoundsPx': selected ? _composerBounds() : null,
      'dispatching': item.dispatching,
      'dispatchFailed': item.dispatchFailed,
      'submissions': item.submissions,
      'finalResponseCharacters': item.finalResponse?.length ?? 0,
      'finalResponseComplete':
          item.mode != null &&
          item.finalResponse?.trimRight().endsWith(item.sentinel) == true,
      'renderReady': measurement?.owned == item
          ? measurement?.renderReady
          : null,
      'pendingParses': measurement?.owned == item
          ? measurement?.pendingParses
          : null,
      'renderedProseCharacters': measurement?.owned == item
          ? measurement?.renderedCharacters
          : null,
      'finalSentinelMounted': measurement?.owned == item
          ? measurement?.finalSentinelMounted
          : null,
    };
  }

  WidgetsBinding.instance.addTimingsCallback((frames) {
    measurement?.timings(frames);
  });
  for (final action in [
    'ready',
    'adopt',
    'prepare',
    'open',
    'stage',
    'submit',
    'snapshot',
    'markDraft',
    'start',
    'stop',
    'cancel',
    'diagnostics',
  ]) {
    developer.registerExtension('ext.wingLive.$action', (_, parameters) async {
      final mutation = !{
        'snapshot',
        'markDraft',
        'start',
        'stop',
        'diagnostics',
      }.contains(action);
      if (mutation && mutating) {
        return developer.ServiceExtensionResponse.error(
          developer.ServiceExtensionResponse.extensionError,
          'Operation busy',
        );
      }
      if (mutation) mutating = true;
      var stage = 'controller';
      try {
        if (action == 'diagnostics') {
          return developer.ServiceExtensionResponse.result(
            jsonEncode(CompletionDiagnostics.snapshot()),
          );
        }
        if (action == 'ready' || action == 'adopt') {
          final controller = _controller();
          final chat = _visibleChat(controller);
          final knownTitle =
              chat?.title.startsWith('Wing streaming stress QA ') == true;
          final luna = RegExp(
            r'^gpt-\d+\.\d+-luna$',
          ).hasMatch(chat?.model ?? '');
          if (action == 'ready') {
            return developer.ServiceExtensionResponse.result(
              jsonEncode({
                'initialized': controller.initialized,
                'currentProfileExists': controller.current != null,
                'currentChatExists': chat != null,
                'knownOwnedTitle': knownTitle,
                'luna': luna,
                'model': chat?.model,
                'provider': chat?.provider,
                'reasoningEffort': chat?.reasoningEffort,
                'composerBoundsPx': _composerBounds(),
              }),
            );
          }
          stage = 'adopt';
          if (chat == null || !knownTitle || !luna) {
            throw StateError('Select a named QA Luna chat');
          }
          stage = 'read_reasoning';
          await controller.loadIntelligence(chat);
          if (!identical(_controller(), controller) ||
              !identical(_visibleChat(controller), chat) ||
              chat.reasoningEffort != 'low') {
            throw StateError('QA chat did not confirm low reasoning');
          }
          var slot = owned.indexWhere((item) => identical(item.chat, chat));
          if (slot < 0) {
            owned.add(_Owned(controller, chat));
            slot = owned.length - 1;
          }
          return developer.ServiceExtensionResponse.result(
            jsonEncode({'slot': slot, ...snapshot(owned[slot])}),
          );
        }
        if (action == 'prepare') {
          final controller = _controller();
          if (!controller.initialized ||
              controller.current == null ||
              _visibleChat(controller)?.runtime.blocksTurnAdmission == true) {
            throw StateError('Wait for the current chat');
          }
          final resource = controller.current!;
          stage = 'read_options';
          final choices =
              ModelCatalog.fromOptions(
                    await resource.gateway.read('model/options'),
                  ).choices
                  .where(
                    (c) =>
                        RegExp(r'^gpt-\d+\.\d+-luna$').hasMatch(c.model) &&
                        (parameters['model'] == null ||
                            c.model == parameters['model']) &&
                        (parameters['provider'] == null ||
                            c.provider == parameters['provider']),
                  )
                  .toList();
          if (choices.length != 1) throw StateError('Ambiguous Luna route');
          final choice = choices.single;
          final title =
              'Wing streaming stress QA ${DateTime.now().millisecondsSinceEpoch}';
          // Explicit synthetic history persists this owned QA session before
          // opening it; no model call or mutation of profile defaults occurs.
          stage = 'create';
          final created = await resource.gateway.call('session.create', {
            'source': 'desktop',
            'close_on_disconnect': false,
            'cwd_explicit': false,
            'model': choice.model,
            'provider': choice.provider,
            'reasoning_effort': 'low',
            'fast': false,
            'title': title,
            'messages': [
              {
                'role': 'user',
                'content': 'Wing performance QA. No tools or delegation.',
              },
              {'role': 'assistant', 'content': 'Ready.'},
            ],
          });
          final info = created['info'];
          final stored = created['stored_session_id'];
          stage = 'verify_create';
          if (stored is! String ||
              stored.isEmpty ||
              info is! Map ||
              info['model'] != choice.model ||
              info['provider'] != choice.provider) {
            throw StateError('Creation did not confirm Luna');
          }
          stage = 'open';
          final chat = await controller.openSession(
            ProfileSessionKey(resource.scope, stored),
          );
          stage = 'verify_resume';
          if (chat == null ||
              chat.model != choice.model ||
              chat.provider != choice.provider) {
            throw StateError('Resume did not confirm Luna');
          }
          // Stock create/resume info omits reasoning. The session-scoped
          // config.get read, owned by the controller, is the actual readback.
          stage = 'read_reasoning';
          await controller.loadIntelligence(chat);
          if (!identical(_controller(), controller) ||
              !identical(_visibleChat(controller), chat) ||
              chat.reasoningEffort != 'low') {
            throw StateError('QA chat did not confirm low reasoning');
          }
          final item = _Owned(controller, chat);
          owned.add(item);
          await controller.mutateSession(
            chat.key,
            changes: {'title': title},
            canDispatch: () =>
                identical(controller.current, resource) &&
                identical(resource.chats[chat.key.sessionId], chat),
          );
          return developer.ServiceExtensionResponse.result(
            jsonEncode({
              'slot': owned.length - 1,
              'ownedTitle': title,
              'ownedSessionId': chat.key.sessionId,
              ...snapshot(item),
            }),
          );
        }
        final item = selected(parameters);
        if ({'open', 'stage', 'submit', 'cancel'}.contains(action)) {
          stage = 'mounted_controller';
          if (!identical(_controller(), item.controller)) {
            throw StateError('Re-adopt the QA chat after native navigation');
          }
        }
        if (action == 'open') await item.controller.openSession(item.chat.key);
        if (action == 'stage' || action == 'submit') {
          final prompt = _prompts[parameters['mode']];
          if (prompt == null ||
              item.chat.runtime.blocksTurnAdmission ||
              item.dispatching ||
              _visibleChat(item.controller) != item.chat ||
              item.chat.composer.observation.displayedText.isNotEmpty ||
              item.chat.composer.observation.attachments.isNotEmpty ||
              item.chat.composer.observation.queue.isNotEmpty ||
              !RegExp(r'^gpt-\d+\.\d+-luna$').hasMatch(item.chat.model ?? '') ||
              item.chat.reasoningEffort != 'low') {
            throw StateError(
              'Owned Luna chat with low reasoning must be selected and empty',
            );
          }
          await item.controller.updateDraft(item.chat, prompt);
          if (!_isSelected(item)) {
            throw StateError('QA chat changed while staging the prompt');
          }
          item.mode = parameters['mode'];
          item.responseBaseCount = item.chat.reading.messages.length;
          item.preservedDraft = null;
          if (action == 'submit') {
            item.dispatching = true;
            item.dispatchFailed = false;
            item.submissions++;
            // One dispatch only. Never retry an uncertain acknowledgement.
            unawaited(
              item.controller
                  .send(item.chat)
                  .catchError((Object _) {
                    item.dispatchFailed = true;
                    return null;
                  })
                  .whenComplete(() => item.dispatching = false),
            );
          }
        }
        if (action == 'cancel') await item.controller.stop(item.chat);
        if (action == 'markDraft') {
          item.preservedDraft = item.chat.composer.observation.displayedText;
        }
        if (action == 'start') {
          if (!_isSelected(item)) {
            throw StateError('Select and adopt the mounted QA chat');
          }
          measurement?.timer.cancel();
          CompletionDiagnostics.reset();
          measurement = _Measurement(item);
        }
        if (action == 'stop') {
          final captured = measurement;
          if (captured == null || captured.owned != item) {
            throw StateError('No matching capture');
          }
          captured.timer.cancel();
          captured.sample();
          final report = {
            ...snapshot(item),
            ...captured.report(),
            'completionDiagnostics': CompletionDiagnostics.snapshot(),
          };
          measurement = null;
          return developer.ServiceExtensionResponse.result(jsonEncode(report));
        }
        return developer.ServiceExtensionResponse.result(
          jsonEncode(snapshot(item)),
        );
      } catch (_) {
        return developer.ServiceExtensionResponse.error(
          developer.ServiceExtensionResponse.extensionError,
          'Live QA operation rejected at $stage.',
        );
      } finally {
        if (mutation) mutating = false;
      }
    });
  }
  app.main();
}
