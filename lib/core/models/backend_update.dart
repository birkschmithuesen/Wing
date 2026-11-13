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
  final int? pid;
  final String? actionId;
  final bool terminal;

  const BackendUpdateReceipt._({
    required this.outcome,
    required this.pid,
    required this.actionId,
    required this.terminal,
  });

  static BackendUpdateReceipt? fromJson(dynamic value) {
    if (value is! Map || value['outcome'] is! String) {
      return null;
    }
    final outcome = (value['outcome'] as String).trim();
    final rawFinishedAt = value['finished_at'];
    final finishedAt = rawFinishedAt is String
        ? DateTime.tryParse(rawFinishedAt)
        : null;
    final actionId = value['action_id'];
    final pid = value['pid'];
    return outcome.isEmpty ||
            pid != null && (pid is! int || pid <= 0) ||
            pid == null && actionId == null ||
            actionId != null &&
                (actionId is! String || actionId.trim().isEmpty) ||
            rawFinishedAt != null && finishedAt == null
        ? null
        : BackendUpdateReceipt._(
            outcome: outcome,
            pid: pid as int?,
            actionId: actionId as String?,
            terminal:
                finishedAt != null &&
                const {
                  'success',
                  'partial',
                  'failed',
                  'refused',
                }.contains(outcome),
          );
  }
}

/// Non-secret device journal for one admitted server update request.
class BackendUpdateAttempt {
  const BackendUpdateAttempt({
    required this.requestId,
    required this.installId,
    required this.installPath,
    required this.home,
    required this.targetSha,
    required this.startedAt,
    this.actionId,
    this.pid,
  });

  final String requestId;
  final String? installId, installPath, home, targetSha;
  final DateTime startedAt;
  final String? actionId;
  final int? pid;

  BackendUpdateAttempt accepted(String id, int? process) =>
      BackendUpdateAttempt(
        requestId: requestId,
        installId: installId,
        installPath: installPath,
        home: home,
        targetSha: targetSha,
        startedAt: startedAt,
        actionId: id,
        pid: process,
      );

  Map<String, Object?> encode() => {
    'schema': 1,
    'request_id': requestId,
    'install_id': installId,
    'install_path': installPath,
    'home': home,
    'target_sha': targetSha,
    'started_at': startedAt.toUtc().toIso8601String(),
    'action_id': actionId,
    'pid': pid,
  };

  static BackendUpdateAttempt decode(Map<String, dynamic> value) {
    String text(String key) {
      final raw = value[key];
      if (raw is! String || raw.trim().isEmpty) {
        throw const FormatException('Invalid saved update tracking');
      }
      return raw;
    }

    if (value['schema'] != 1) {
      throw const FormatException('Invalid saved update tracking');
    }
    String? optionalText(String key) => value[key] == null ? null : text(key);
    final startedAt = DateTime.tryParse(text('started_at'));
    final actionId = value['action_id'];
    final pid = value['pid'];
    if (startedAt == null ||
        actionId == null && pid != null ||
        actionId != null && (actionId is! String || actionId.trim().isEmpty) ||
        pid != null && (pid is! int || pid <= 0)) {
      throw const FormatException('Invalid saved update tracking');
    }
    return BackendUpdateAttempt(
      requestId: text('request_id'),
      installId: optionalText('install_id'),
      installPath: optionalText('install_path'),
      home: optionalText('home'),
      targetSha: optionalText('target_sha'),
      startedAt: startedAt,
      actionId: actionId as String?,
      pid: pid as int?,
    );
  }
}

class BackendUpdateStatus {
  final bool running;
  final int? pid;
  final int? exitCode;
  final String? actionId;
  final List<String> lines;
  final BackendUpdateReceipt? receipt;

  const BackendUpdateStatus({
    required this.running,
    required this.pid,
    required this.exitCode,
    required this.actionId,
    required this.lines,
    required this.receipt,
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
      receipt: BackendUpdateReceipt.fromJson(value['receipt']),
    );
  }
}
