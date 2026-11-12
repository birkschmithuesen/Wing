import 'package:share_plus/share_plus.dart';

/// A second offer must not supersede a native share still preparing its files.
class PlatformShareBusy implements Exception {
  const PlatformShareBusy();
  String get message => 'Finish the current share sheet, then try again.';
  @override
  String toString() => message;
}

bool _sharing = false;

/// One admitted platform offer across backup, output and text sharing.
///
/// share_plus resolves the previous result when a second offer enters, even if
/// its background file copy is still running. Reject overlap before calling the
/// plugin so settlement safely releases the caller's original staging files.
Future<ShareResult> platformShare(
  ShareParams params, {
  void Function()? onDispatched,
}) async {
  if (_sharing) throw const PlatformShareBusy();
  _sharing = true;
  try {
    onDispatched?.call();
    return await SharePlus.instance.share(params);
  } finally {
    _sharing = false;
  }
}
