enum BackendUpdatePhase {
  idle,
  ready,
  starting,
  running,
  succeeded,
  partial,
  refused,
  failed,
  unknown,
}

class BackendUpdateCheck {
  final String? currentVersion;
  final String? installMethod;
  final int? behind;
  final bool? updateAvailable;
  final bool? canApply;
  final String? message;
  final String? rollbackTo;
  final bool failed;
  final List<BackendUpdateCommit> commits;

  const BackendUpdateCheck({
    required this.currentVersion,
    required this.installMethod,
    required this.behind,
    required this.updateAvailable,
    required this.canApply,
    required this.message,
    required this.rollbackTo,
    required this.failed,
    required this.commits,
  });

  factory BackendUpdateCheck.fromJson(Map<String, dynamic> value) {
    String? text(String key) {
      final raw = value[key];
      return raw is String && raw.trim().isNotEmpty ? raw.trim() : null;
    }

    final rawBehind = value['behind'];
    return BackendUpdateCheck(
      currentVersion: text('current_version'),
      installMethod: text('install_method'),
      behind: rawBehind is int && rawBehind >= 0 ? rawBehind : null,
      updateAvailable: value['update_available'] is bool
          ? value['update_available'] as bool
          : null,
      canApply: value['can_apply'] is bool ? value['can_apply'] as bool : null,
      message: text('message'),
      rollbackTo: text('rollback_to'),
      failed:
          value['can_apply'] == true && (rawBehind is! int || rawBehind < -1),
      commits: List.unmodifiable([
        if (value['commits'] case final List rows)
          for (final row in rows.take(20)) ?BackendUpdateCommit.fromJson(row),
      ]),
    );
  }

  bool get canStart => !failed && canApply == true && updateAvailable == true;
}

/// One stock source-check observation, bound to a single install and profile home.
class BackendUpdateChannel {
  const BackendUpdateChannel({
    required this.installId,
    required this.installPath,
    required this.home,
    required this.name,
    required this.branch,
    required this.currentSha,
    required this.targetSha,
    required this.targetVersion,
    required this.error,
    required this.aheadOfRelease,
    required this.rollback,
    required this.fetchedAt,
  });

  final String installId, installPath, home, name, currentSha;
  final String? branch, targetSha, targetVersion, error;
  final bool aheadOfRelease, rollback;
  final int fetchedAt;

  String get label => name == 'main' && branch != null && branch != 'main'
      ? 'Branch: $branch'
      : 'Channel: $name';

  bool get canSelect => name != 'main' || branch == 'main';

  bool sameInstallation(BackendUpdateChannel other) =>
      installId == other.installId &&
      installPath == other.installPath &&
      home == other.home &&
      currentSha == other.currentSha;

  /// Main follows the approved branch's moving tip. Release targets are fixed.
  bool sameUpdateIntent(BackendUpdateChannel other) =>
      sameInstallation(other) &&
      name == other.name &&
      branch == other.branch &&
      (name == 'main' || targetSha == other.targetSha) &&
      rollback == other.rollback;
}

class BackendUpdateCommit {
  final String summary;
  final String? sha;
  final String? author;
  final DateTime? date;

  const BackendUpdateCommit({
    required this.summary,
    required this.sha,
    required this.author,
    required this.date,
  });

  static BackendUpdateCommit? fromJson(dynamic value) {
    if (value is! Map) return null;
    String? text(String key) {
      final raw = value[key];
      return raw is String && raw.trim().isNotEmpty ? raw.trim() : null;
    }

    final summary = text('summary');
    if (summary == null) return null;
    final at = value['at'];
    return BackendUpdateCommit(
      summary: summary,
      sha: text('sha'),
      author: text('author'),
      date: at is int && at > 0 && at <= 253402300799
          ? DateTime.fromMillisecondsSinceEpoch(at * 1000, isUtc: true)
          : null,
    );
  }
}

class BackendUpdateReceipt {
  final String outcome;
  final int pid;

  const BackendUpdateReceipt({required this.outcome, required this.pid});

  static BackendUpdateReceipt? fromJson(dynamic value) {
    if (value is! Map ||
        value['outcome'] is! String ||
        value['pid'] is! int ||
        value['finished_at'] is! String) {
      return null;
    }
    final outcome = (value['outcome'] as String).trim();
    final finishedAt = (value['finished_at'] as String).trim();
    final pid = value['pid'] as int;
    return outcome.isEmpty || pid <= 0 || DateTime.tryParse(finishedAt) == null
        ? null
        : BackendUpdateReceipt(outcome: outcome, pid: pid);
  }
}

class BackendUpdateStatus {
  final bool running;
  final int? pid;
  final int? exitCode;
  final String? actionId;
  final List<String> lines;

  const BackendUpdateStatus({
    required this.running,
    required this.pid,
    required this.exitCode,
    required this.actionId,
    required this.lines,
  });

  static BackendUpdateStatus? fromJson(Map<String, dynamic> value) {
    final rawId = value['action_id'];
    final rawLines = value['lines'];
    if (value['running'] is! bool ||
        rawId != null && (rawId is! String || rawId.trim().isEmpty) ||
        rawLines is! List ||
        !rawLines.every((line) => line is String)) {
      return null;
    }
    int? integer(String key) {
      final raw = value[key];
      return raw is int ? raw : null;
    }

    final actionId = rawId as String?;
    final lines = rawLines
        .cast<String>()
        .map((line) => line.replaceAll('\u0000', ''))
        .where((line) => line.trim().isNotEmpty)
        .take(200)
        .map((line) => line.length <= 1000 ? line : line.substring(0, 1000))
        .toList(growable: false);
    return BackendUpdateStatus(
      running: value['running'] as bool,
      pid: integer('pid'),
      exitCode: integer('exit_code'),
      actionId: actionId,
      lines: lines,
    );
  }
}
