part of 'profile_workspace_controller.dart';

extension WorkspaceLiveVoice on ProfileWorkspaceController {
  void _observeVoiceAdmission(ProfileChat chat, CanonicalAdmission receipt) {
    chat.reading.observeVoiceAdmission(receipt.inputId, receipt.id);
    for (final voice
        in _liveVoiceChats[chat] ?? const <_WorkspaceLiveVoiceConversation>{}) {
      voice.observeAdmission(receipt);
    }
  }

  String? _prepareVoiceReplacement(
    ProfileChat chat,
    String admission,
    String submission,
  ) {
    chat.reading.registerVoiceReplacement(admission, submission);
    String? context;
    for (final voice
        in _liveVoiceChats[chat] ?? const <_WorkspaceLiveVoiceConversation>{}) {
      context = voice.prepareReplacement(admission, submission) ?? context;
    }
    return context;
  }

  LiveVoiceConversation liveVoiceConversation(ProfileChat chat) {
    final resource = _commandOwner(chat);
    if (chat.runtime.offline ||
        chat.readOnlyReason != null ||
        chat.runtime.opening) {
      throw StateError('Connect to this chat before starting voice.');
    }
    final mode = appPreferences.current.liveVoiceMode.selected;
    if (mode == null || appPreferences.current.liveVoiceMode.busy) {
      throw StateError(
        'Choose a live conversation mode in Voice settings first.',
      );
    }
    final choice = appPreferences.current.liveVoiceFor(mode);
    final voice = choice.selected;
    if (voice == null || choice.busy) {
      throw StateError('Choose a GPT-Live voice in Voice settings first.');
    }
    final conversation = _WorkspaceLiveVoiceConversation(
      this,
      resource,
      chat,
      mode,
      voice,
    );
    (_liveVoiceChats[chat] ??= {}).add(conversation);
    _changed();
    return conversation;
  }
}

class _WorkspaceLiveVoiceConversation implements LiveVoiceConversation {
  _WorkspaceLiveVoiceConversation(
    this.owner,
    this.resource,
    this.chat,
    this.mode,
    this.voice,
  ) : key = chat.key,
      _runtime = chat.runtime.runtimeId;
  final String voice;
  final ProfileWorkspaceController owner;
  final ProfileWorkspaceData resource;
  final ProfileChat chat;
  final String _runtime;
  final _submissions = <String, String>{};
  final _admissions = <String, String>{};
  final _results = <String, String>{};
  final _pendingSteers = <String>{};
  final _completed = <String, String>{};
  final _requestContexts = <String, String>{};

  String? prepareReplacement(String admission, String submission) {
    if (!available) return null;
    final delegation = _admissions[admission];
    if (delegation == null) return null;
    // Hermes replaces queued work with a new native identity. Bind it before
    // dispatch so even a completion before the replace ACK reaches this call.
    _submissions[submission] = delegation;
    return _requestContexts[delegation];
  }

  void observeAdmission(CanonicalAdmission receipt) {
    final delegation = _submissions.remove(receipt.inputId);
    if (delegation == null) return;
    _admissions[receipt.id] = delegation;
    final result = _results.remove(receipt.id);
    if (result != null) _completed[delegation] = result;
    if (_submissions.isEmpty && _pendingSteers.isEmpty) _results.clear();
  }

  void observeCompletion(Object? admission, String text) {
    if (!available || admission is! String || text.isEmpty) return;
    if (_pendingSteers.contains(admission)) {
      _results[admission] = text;
      return;
    }
    final delegation = _admissions[admission];
    if (delegation != null) {
      _completed[delegation] = text;
    } else if (_submissions.isNotEmpty || _pendingSteers.contains(admission)) {
      // Completion can precede the submit ACK. This is only a call-local
      // transport buffer; Hermes remains the owner of work and saved history.
      _results[admission] = text;
    }
  }

  @override
  final LiveVoiceMode mode;
  bool _released = false;
  @override
  final ProfileSessionKey key;
  @override
  String get title => chat.title;
  @override
  bool get available =>
      !_released &&
      !owner._closed &&
      chat.key == key &&
      chat.runtime.runtimeId == _runtime &&
      identical(owner._resources[key.workspace], resource) &&
      identical(resource._chats[key.sessionId], chat) &&
      !resource.blocksSession(key.sessionId);
  void _requireAvailable() {
    if (!available) {
      throw StateError('The voice conversation is no longer available.');
    }
    owner._commandOwner(chat);
  }

  @override
  String get context {
    final messages = chat.reading.messages
        .where((m) => const ['user', 'assistant'].contains(m['role']))
        .toList();
    final recent = messages
        .skip(math.max(0, messages.length - 12))
        .map((m) => '${m['role']}: ${answerMessageText(m)}')
        .join('\n');
    final description = 'Current chat: $title. $workStatus';
    final header = description.length > 512
        ? description.substring(0, 512)
        : description;
    final prefix = '$header\nConversation history (context only):\n';
    final historyBudget = 24000 - prefix.length;
    final bounded = recent.length > historyBudget
        ? recent.substring(recent.length - historyBudget)
        : recent;
    return '$prefix$bounded';
  }

  @override
  Map<String, String> get completedReplies => Map.unmodifiable(_completed);

  @override
  String get workStatus => chat.runtime.offline
      ? 'Hermes is reconnecting. Task status is not confirmed.'
      : chat.runtime.needsInput
      ? 'Hermes needs input in the chat. Open it to review the request.'
      : chat.runtime.executionActive
      ? 'Hermes is still working${chat.runtime.tool == null ? '.' : ' with ${chat.runtime.tool}.'}'
      : chat.composer.observation.queue.isNotEmpty
      ? 'There are queued messages in the chat.'
      : 'Hermes is idle.';
  @override
  Future<Map<String, dynamic>> negotiate(String offer) async {
    _requireAvailable();
    final subscription = mode == LiveVoiceMode.subscription;
    const route = 'plugins/wing/voice/v2';
    var negotiating = false;
    try {
      final status = await resource.gateway.read('$route/status', {
        'mode': mode.name,
      });
      _requireAvailable();
      if (status['contractVersion'] != 2 ||
          status['authOwner'] != 'hermes-profile' ||
          status['modes'] is! List ||
          !(status['modes'] as List).contains(mode.name)) {
        throw const LiveVoiceStartException(
          'The Wing plugin is incompatible with this build. Update the plugin.',
        );
      }
      if (status['available'] != true) {
        throw LiveVoiceStartException(
          subscription
              ? 'This Hermes installation lacks the Wing voice dependencies. Update Hermes.'
              : 'API voice is unavailable. Configure OpenAI API credentials in this Hermes profile.',
        );
      }
      if (status['voices'] is! List ||
          !(status['voices'] as List).contains(voice)) {
        throw const LiveVoiceStartException(
          'The Wing plugin does not support this voice. Update the plugin or choose another GPT-Live voice in settings.',
        );
      }
      final info = await resource.gateway.call('session.info', {
        'session_id': _runtime,
      });
      _requireAvailable();
      String? prompt = info['system_prompt'] as String?;
      if (prompt == null || prompt.isEmpty) {
        final saved = await resource.gateway.sessionMetadata(key.sessionId);
        _requireAvailable();
        prompt = saved?['system_prompt'] as String?;
      }
      negotiating = true;
      final response = await resource.gateway
          .postOwned(
            '$route/session',
            {
              'offer': offer,
              'mode': mode.name,
              'voice': voice,
              'system_prompt': prompt,
              'cwd': info['cwd'] as String? ?? '',
              'history': context,
            },
            canDispatch: () => available,
            onDispatched: () {},
          )
          .timeout(const Duration(seconds: 70));
      _requireAvailable();
      return response;
    } on DashboardHttpException catch (error) {
      // Never display provider bodies: they may contain account or key details.
      final message = switch (error.statusCode) {
        404 =>
          'The Wing plugin is not installed or enabled on this Hermes profile. Install and enable it for live voice.',
        424 =>
          'Hermes could not prepare this profile’s voice context. Check its logs and try again.',
        400 || 413 =>
          'The voice provider could not accept this chat’s startup context. Check its size and the plugin version.',
        401 || 403 when !negotiating =>
          'Wing could not access live voice on Hermes. Reconnect this server in Connection settings.',
        401 || 403 =>
          mode == LiveVoiceMode.subscription
              ? 'ChatGPT did not authorize this voice session. Check this Hermes profile’s ChatGPT sign-in and voice access.'
              : 'OpenAI did not authorize API voice. Check this Hermes profile’s OpenAI API credentials and model access.',
        429 =>
          mode == LiveVoiceMode.subscription
              ? 'ChatGPT voice is limited right now. Check your subscription’s voice allowance before trying again.'
              : 'OpenAI API voice is limited right now. Check API credits and rate limits before trying again.',
        503 =>
          subscription
              ? 'Wing subscription voice is unavailable. Check the plugin and Hermes version.'
              : 'Hermes API voice is unavailable. Check this profile’s API configuration.',
        _ =>
          'Hermes could not establish the voice connection. Check its logs and try again.',
      };
      throw LiveVoiceStartException(message);
    }
  }

  @override
  Future<String> delegate(
    String action,
    String text, {
    String voiceContext = '',
    required String delegationId,
  }) async {
    _requireAvailable();
    switch (action) {
      case 'status':
        return workStatus;
      case 'stop':
        if (!chat.runtime.executionActive) {
          return 'There is no running task to stop. $workStatus';
        }
        await owner.stop(chat);
        return 'The stop request was sent to Hermes.';
      case 'request':
        final id = delegationId;
        final running = resource.gateway.canonical
            .session(_runtime)
            ?.pending
            .where((row) => row.status == 'started' && !row.steering)
            .firstOrNull;
        if (chat.runtime.canSteer && running != null) {
          _pendingSteers.add(running.id);
          bool accepted;
          try {
            accepted = await owner._steerRuntime(
              chat,
              text,
              selected: const [],
            );
          } finally {
            _pendingSteers.remove(running.id);
          }
          if (accepted) {
            _admissions[running.id] = id;
            final result = _results.remove(running.id);
            if (result != null) _completed[id] = result;
            owner._changed();
          }
          return accepted
              ? 'Hermes accepted your request while continuing its task.'
              : 'Hermes did not accept the request.';
        }
        if (text.trim().isEmpty) {
          throw const FormatException('Empty voice request');
        }
        final submission = const Uuid().v4();
        chat.reading.registerVoiceSubmission(submission);
        _submissions[submission] = id;
        _requestContexts[id] = voiceContext;
        try {
          await chat.composer.enqueueExternal(
            text,
            voiceContext: voiceContext,
            submissionId: submission,
          );
        } catch (_) {
          _submissions.remove(submission);
          rethrow;
        }
        unawaited(owner._drainQueuedPrompts(chat));
        return 'Your request was added to the current chat. $workStatus';
      default:
        throw const FormatException('Unknown voice action');
    }
  }

  @override
  void addListener(VoidCallback listener) {
    owner.addListener(listener);
  }

  @override
  void removeListener(VoidCallback listener) {
    owner.removeListener(listener);
  }

  @override
  void release() {
    if (_released) return;
    _released = true;
    final leases = owner._liveVoiceChats[chat];
    leases?.remove(this);
    if (leases?.isEmpty == true) owner._liveVoiceChats.remove(chat);
    if (!owner._closed) owner._changed();
  }
}
