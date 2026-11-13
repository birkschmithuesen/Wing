/// Device colour choices. Storage and theme rendering interpret these facts in
/// their own layers; malformed stored presence is distinct from Automatic.
enum ProfileColorChoice {
  automatic(null),
  red(0),
  orange(1),
  yellow(2),
  lime(3),
  green(4),
  spring(5),
  cyan(6),
  azure(7),
  blue(8),
  violet(9),
  magenta(10),
  rose(11);

  const ProfileColorChoice(this.slot);
  final int? slot;
}

class ProfileColorFact {
  const ProfileColorFact({
    required this.displayChoice,
    required this.selected,
    required this.busy,
    required this.notice,
    required this.error,
    required this.canChoose,
    required this.reloadVisible,
    required this.reloading,
    required this.reload,
  });

  final ProfileColorChoice? displayChoice;
  final ProfileColorChoice? selected;
  final bool busy;
  final String? notice;
  final String? error;
  final bool canChoose;
  final bool reloadVisible;
  final bool reloading;
  final Future<bool> Function()? reload;

  @override
  bool operator ==(Object other) =>
      other is ProfileColorFact &&
      displayChoice == other.displayChoice &&
      selected == other.selected &&
      busy == other.busy &&
      notice == other.notice &&
      error == other.error &&
      canChoose == other.canChoose &&
      reloadVisible == other.reloadVisible &&
      reloading == other.reloading &&
      reload == other.reload;

  @override
  int get hashCode => Object.hash(
    displayChoice,
    selected,
    busy,
    notice,
    error,
    canChoose,
    reloadVisible,
    reloading,
    reload,
  );
}

class ProfileColorsState {
  ProfileColorsState(Map<String, ProfileColorFact> profiles)
    : profiles = Map.unmodifiable(profiles);

  final Map<String, ProfileColorFact> profiles;
}
