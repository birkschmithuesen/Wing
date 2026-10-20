/// The notice of contract §4. All text is rendered by the server; Wing shows it as given.
class PorterNotice {
  const PorterNotice({
    required this.v,
    required this.noticeId,
    required this.mode,
    required this.kind,
    required this.level,
    required this.title,
    required this.lines,
    required this.items,
    required this.actions,
    required this.openProfile,
    required this.feedback,
  });

  final int v;
  final String noticeId;
  final String mode;
  final String kind;
  final String level;
  final String title;
  final List<String> lines;
  final List<PorterNoticeItem> items;
  final List<PorterNoticeAction> actions;
  final String openProfile;
  final PorterNoticeFeedback feedback;

  bool get isTrial => mode == 'trial';

  static const knownActions = {'open', 'snooze', 'rate'};

  factory PorterNotice.fromJson(Map<String, dynamic> json) {
    try {
      final lines = json['lines'] as List;
      return PorterNotice(
        v: json['v'] as int,
        noticeId: json['notice_id'] as String,
        mode: json['mode'] as String? ?? 'live',
        kind: json['kind'] as String? ?? 'items',
        level: json['level'] as String? ?? 'yellow',
        title: json['title'] as String,
        lines: [for (final line in lines) line as String],
        items: [
          for (final item in json['items'] as List? ?? const [])
            PorterNoticeItem.fromJson(Map<String, dynamic>.from(item as Map)),
        ],
        actions: [
          for (final raw in json['actions'] as List? ?? const [])
            if (raw is Map && knownActions.contains(raw['id']))
              PorterNoticeAction.fromJson(Map<String, dynamic>.from(raw)),
        ],
        openProfile: json['open_profile'] as String? ?? 'pforte',
        feedback: PorterNoticeFeedback.fromJson(
          Map<String, dynamic>.from(json['feedback'] as Map? ?? const {}),
        ),
      );
    } on TypeError catch (error) {
      throw FormatException('Malformed porter notice: $error');
    }
  }
}

class PorterNoticeItem {
  const PorterNoticeItem({
    required this.itemId,
    required this.sessionId,
    required this.profile,
    required this.block,
    required this.line,
    this.why,
    this.snoozeLabel,
  });

  final String itemId;
  final String sessionId;
  final String profile;
  final String block;
  final String line;
  final String? why;
  final String? snoozeLabel;

  factory PorterNoticeItem.fromJson(Map<String, dynamic> json) =>
      PorterNoticeItem(
        itemId: json['item_id'] as String,
        sessionId: json['session_id'] as String,
        profile: json['profile'] as String,
        block: json['block'] as String,
        line: json['line'] as String,
        why: json['why'] as String?,
        snoozeLabel: json['snooze_label'] as String?,
      );
}

class PorterNoticeAction {
  const PorterNoticeAction({
    required this.id,
    required this.label,
    this.value,
    this.defaultValue,
  });

  final String id;
  final String label;
  final String? value;
  final String? defaultValue;

  factory PorterNoticeAction.fromJson(Map<String, dynamic> json) =>
      PorterNoticeAction(
        id: json['id'] as String,
        label: json['label'] as String,
        value: json['value'] as String?,
        defaultValue: json['default'] as String?,
      );
}

class PorterNoticeFeedback {
  const PorterNoticeFeedback({this.rating, this.snoozedUntil, this.opened = false});

  final String? rating;
  final String? snoozedUntil;
  final bool opened;

  factory PorterNoticeFeedback.fromJson(Map<String, dynamic> json) =>
      PorterNoticeFeedback(
        rating: json['rating'] as String?,
        snoozedUntil: json['snoozed_until'] as String?,
        opened: json['opened'] == true,
      );
}
