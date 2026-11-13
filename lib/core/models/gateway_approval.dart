enum GatewayApprovalChoice {
  once('once'),
  session('session'),
  always('always'),
  deny('deny');

  final String wireValue;

  const GatewayApprovalChoice(this.wireValue);

  static GatewayApprovalChoice? fromWireValue(String value) {
    for (final choice in values) {
      if (choice.wireValue == value) return choice;
    }
    return null;
  }
}

/// Ordered, request-correlated approvals for one runtime session. Replays update
/// an existing entry rather than replacing whichever command is being reviewed.
class GatewayApprovalQueue {
  final List<Map<String, dynamic>> _requests = [];
  int total = 0;
  int revision = 0;

  List<Map<String, dynamic>> get requests => List.unmodifiable(_requests);
  int get position => total - _requests.length + 1;

  bool add(Map<String, dynamic> request) {
    final id = request['request_id'];
    if (id is! String || id.isEmpty) return false;
    final index = _requests.indexWhere((item) => item['request_id'] == id);
    revision++;
    if (index >= 0) {
      _requests[index] = {..._requests[index], ...request};
      return false;
    }
    if (_requests.isEmpty) total = 0;
    _requests.add(Map.of(request));
    total++;
    return true;
  }

  void remove(String id) {
    _requests.removeWhere((item) => item['request_id'] == id);
    revision++;
    if (_requests.isEmpty) total = 0;
  }

  void clear() {
    _requests.clear();
    total = 0;
    revision++;
  }

  void reconcile(List<Map<String, dynamic>> requests) {
    final ids = requests.map((request) => request['request_id']).toSet();
    _requests.removeWhere((request) => !ids.contains(request['request_id']));
    for (final request in requests) {
      add(request);
    }
    if (_requests.isEmpty) total = 0;
    revision++;
  }
}

/// A command approval emitted by the Hermes Desktop gateway.
///
/// The backend is authoritative about the available scopes. Android also
/// removes unsafe combinations defensively so a malformed event cannot expose
/// a permanent approval when Hermes says it is unavailable.
class GatewayApprovalRequest {
  final String command;
  final String description;
  final bool allowPermanent;
  final bool smartDenied;
  final List<GatewayApprovalChoice> choices;

  const GatewayApprovalRequest({
    required this.command,
    required this.description,
    required this.allowPermanent,
    required this.smartDenied,
    required this.choices,
  });

  factory GatewayApprovalRequest.fromEventData(Map<String, dynamic> data) {
    final smartDenied = data['smart_denied'] == true;
    final allowSession = data['allow_session'] != false && !smartDenied;
    final allowPermanent = data['allow_permanent'] != false && allowSession;
    final rawChoices = data['choices'];
    final parsedChoices = <GatewayApprovalChoice>[];

    if (rawChoices is List) {
      for (final rawChoice in rawChoices) {
        final choice = GatewayApprovalChoice.fromWireValue(
          rawChoice.toString(),
        );
        if (choice != null && !parsedChoices.contains(choice)) {
          parsedChoices.add(choice);
        }
      }
    }

    final choices = rawChoices is! List
        ? !allowSession
              ? <GatewayApprovalChoice>[
                  GatewayApprovalChoice.once,
                  GatewayApprovalChoice.deny,
                ]
              : allowPermanent
              ? <GatewayApprovalChoice>[
                  GatewayApprovalChoice.once,
                  GatewayApprovalChoice.session,
                  GatewayApprovalChoice.always,
                  GatewayApprovalChoice.deny,
                ]
              : <GatewayApprovalChoice>[
                  GatewayApprovalChoice.once,
                  GatewayApprovalChoice.session,
                  GatewayApprovalChoice.deny,
                ]
        : parsedChoices.where((choice) {
            if (!allowSession) {
              return choice == GatewayApprovalChoice.once ||
                  choice == GatewayApprovalChoice.deny;
            }
            if (!allowPermanent && choice == GatewayApprovalChoice.always) {
              return false;
            }
            return true;
          }).toList();

    return GatewayApprovalRequest(
      command: data['command']?.toString() ?? '',
      description:
          data['description']?.toString().trim() ??
          'Hermes wants to run a command.',
      allowPermanent: allowPermanent,
      smartDenied: smartDenied,
      choices: List.unmodifiable(choices),
    );
  }
}
