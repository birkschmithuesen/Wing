import 'package:flutter/widgets.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Shared action glyphs from the fonts in assets/fonts.
abstract final class WingIcons {
  static void registerLicense() {
    LicenseRegistry.addLicense(() async* {
      yield LicenseEntryWithLineBreaks([
        'Tabler Icons',
      ], await rootBundle.loadString('assets/fonts/TABLER-LICENSE'));
    });
  }

  /// The selected Lucide square-pen, used for every New chat action.
  static const newChat = IconData(0xe175, fontFamily: 'WingIcons');

  /// Lucide git-fork, matching the desktop conversation's fork action.
  static const fork = IconData(0xe28c, fontFamily: 'WingIcons');

  /// Codicons layers, matching the desktop queued-message section.
  static const queue = IconData(0xebd2, fontFamily: 'WingProjectIcons');

  /// Tabler steering-wheel, matching the desktop Steer action.
  static const steer = IconData(0xe001, fontFamily: 'WingIcons');
}
