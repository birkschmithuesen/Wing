/// Membership counts from one confirmed connection-manager transaction,
/// observed under the same persistence ordering as that transaction.
class ConnectionImportResult {
  const ConnectionImportResult({
    required this.added,
    required this.updated,
    required this.removed,
  });

  final int added;
  final int updated;
  final int removed;
}
