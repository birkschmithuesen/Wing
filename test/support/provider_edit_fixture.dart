import 'dart:async';
import 'dart:convert';
import 'administration_fixture.dart';

class ProviderEditFixture extends AdministrationFixture {
  ProviderEditFixture() {
    mutationOverride = (method, path, query, body, canDispatch, onDispatched) {
      Future<Map<String, dynamic>> run() async {
        try {
          if (!mutationEntered.isCompleted) {
            mutationEntered.complete();
          }
          if (heldMutationEntered != null &&
              !heldMutationEntered!.isCompleted) {
            heldMutationEntered!.complete();
          }
          await mutationGate?.future;
          if (!canDispatch()) {
            throw StateError('Provider command retired');
          }
          onDispatched();
          return await send(method, path, query, body);
        } finally {
          if (!mutationExited.isCompleted) {
            mutationExited.complete();
          }
        }
      }

      final operation = run();
      return timeoutMutation ? operation.timeout(Duration.zero) : operation;
    };
  }
  static Map<String, dynamic> field({
    bool isSet = false,
    bool managed = false,
    String category = 'api_keys',
    String label = 'Example',
  }) => {
    'is_set': isSet,
    'channel_managed': managed,
    'category': category,
    'provider_label': label,
  };
  final env = <String, dynamic>{'EXAMPLE_API_KEY': field()};
  List<Map<String, dynamic>> providers = [
    {
      'id': 'provider',
      'name': 'Provider',
      'flow': 'device_code',
      'status': {'logged_in': false},
    },
  ];
  Map<String, dynamic> startResponse = {
    'session_id': 'owned-session',
    'flow': 'device_code',
    'user_code': 'fixture-code',
    'verification_url': 'https://example.invalid/sign-in',
    'expires_in': 900,
    'poll_interval': 60,
  };
  Map<String, dynamic> pollResponse = {
    'session_id': 'owned-session',
    'status': 'pending',
  };
  Completer<void>? mutationGate,
      membershipGate,
      startGate,
      envWriteGate,
      heldMutationEntered;
  Completer<Map<String, dynamic>>? pollGate;
  final mutationEntered = Completer<void>();
  final mutationExited = Completer<void>();
  final membershipEntered = Completer<void>();
  final startEntered = Completer<void>();
  final writeEntered = Completer<void>();
  final pollEntered = Completer<void>();
  bool timeoutMutation = false,
      acknowledge = true,
      apply = true,
      wrongKey = false,
      failSelections = false;
  int envWrites = 0, starts = 0, polls = 0;
  final cancelled = <String>[];
  Object? copy(Object? value) => jsonDecode(jsonEncode(value));
  @override
  Future<Map<String, dynamic>> send(
    String method,
    String path,
    Map<String, String> query,
    Map<String, dynamic>? body,
  ) async {
    if (path == 'profiles' && membershipGate != null) {
      if (!membershipEntered.isCompleted) {
        membershipEntered.complete();
      }
      await membershipGate!.future;
    }
    if (path == 'profiles' && failSelections) {
      throw StateError('Unavailable');
    }
    if (path == 'env' || path.startsWith('providers/oauth')) {
      requests.add((method, path, {...query}, body));
      if (query['profile'] != 'personal') {
        throw StateError('Wrong provider owner');
      }
    }
    if (path == 'env') {
      if (method == 'GET') {
        return copy(env) as Map<String, dynamic>;
      }
      if (!{'PUT', 'DELETE'}.contains(method)) {
        throw StateError('Wrong env verb');
      }
      envWrites++;
      if (!writeEntered.isCompleted) {
        writeEntered.complete();
      }
      await envWriteGate?.future;
      if (acknowledge && apply) {
        (env[body!['key']] as Map)['is_set'] = method == 'PUT';
      }
      return {
        'ok': acknowledge,
        'key': wrongKey ? 'DIFFERENT_API_KEY' : body!['key'],
      };
    }
    if (path == 'providers/oauth') {
      return {'providers': copy(providers)};
    }
    if (path.endsWith('/start')) {
      starts++;
      if (!startEntered.isCompleted) {
        startEntered.complete();
      }
      await startGate?.future;
      return copy(startResponse) as Map<String, dynamic>;
    }
    if (path.contains('/poll/')) {
      polls++;
      if (!pollEntered.isCompleted) {
        pollEntered.complete();
      }
      return pollGate?.future ?? copy(pollResponse) as Map<String, dynamic>;
    }
    if (path.startsWith('providers/oauth/sessions/') && method == 'DELETE') {
      final id = Uri.decodeComponent(path.split('/').last);
      cancelled.add(id);
      return {'ok': acknowledge, 'session_id': id};
    }
    return super.send(method, path, query, body);
  }
}
