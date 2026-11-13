/// Destinations are identities; their display labels never select wire reads.
enum ProfileOverviewDestination {
  models('Models and reasoning'),
  identity('Identity'),
  memory('Memory'),
  behavior('Behavior'),
  skills('Skills and tools'),
  skillHub('Skill Hub'),
  access('Access and connectors'),
  connectors('MCP connectors'),
  scheduledTasks('Scheduled tasks');

  const ProfileOverviewDestination(this.label);
  final String label;
}

sealed class OverviewTextPart {
  const OverviewTextPart();
}

final class OverviewLiteral extends OverviewTextPart {
  const OverviewLiteral(this.value);
  final String value;
}

final class OverviewInteger extends OverviewTextPart {
  const OverviewInteger(this.value);
  final int value;
}

final class OverviewCheckedTime extends OverviewTextPart {
  const OverviewCheckedTime(this.value);
  final DateTime value;
}

final class OverviewTaskTime extends OverviewTextPart {
  const OverviewTaskTime(this.value);
  final DateTime value;
}

/// Passive text with localization inputs preserved until rendering. No wire
/// records, mutable observations or controller state escape through this DTO.
class OverviewText {
  OverviewText.parts(Iterable<OverviewTextPart> parts)
    : parts = List.unmodifiable(parts);
  OverviewText(String value)
    : parts = List.unmodifiable([OverviewLiteral(value)]);
  final List<OverviewTextPart> parts;

  OverviewText followedBy(OverviewText other) =>
      OverviewText.parts([...parts, ...other.parts]);

  String render({
    required String Function(int) integer,
    required String Function(DateTime) checkedTime,
    required String Function(DateTime) taskTime,
  }) => parts
      .map(
        (part) => switch (part) {
          OverviewLiteral(:final value) => value,
          OverviewInteger(:final value) => integer(value),
          OverviewCheckedTime(:final value) => checkedTime(value),
          OverviewTaskTime(:final value) => taskTime(value),
        },
      )
      .join();
}

class ProfileOverviewRow {
  const ProfileOverviewRow({
    required this.destination,
    required this.summary,
    this.attention,
    this.detail,
  });
  final ProfileOverviewDestination destination;
  final OverviewText summary;
  final String? attention;
  final String? detail;
}

class ProfileOverviewSummary {
  ProfileOverviewSummary({
    required this.modelTitle,
    required this.modelMetadata,
    required this.modelAttention,
    required Map<ProfileOverviewDestination, ProfileOverviewRow> rows,
  }) : rows = Map.unmodifiable(rows);
  final String modelTitle;
  final OverviewText modelMetadata;
  final String? modelAttention;
  final Map<ProfileOverviewDestination, ProfileOverviewRow> rows;
}
