/// A completed observation from an existing reader, not a new monitor.
/// A null error means that this exact operation was successfully observed.
final class OperationalErrorObservation {
  const OperationalErrorObservation({
    required this.connectionIdentity,
    required this.operation,
    required this.title,
    required this.error,
    this.profileName,
  });

  final String connectionIdentity;
  final String operation;
  final String title;
  final String? error;
  final String? profileName;
}

typedef OperationalErrorReporter = void Function(OperationalErrorObservation);
