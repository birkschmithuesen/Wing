import 'package:flutter_test/flutter_test.dart';
import 'notification_action_background_test.dart'
    show checkDisconnectedNotification;

void main() {
  testWidgets(
    'hidden previews force review even when delivered review flag is false',
    (tester) => checkDisconnectedNotification(
      tester,
      review: false,
      hidePreviews: true,
    ),
  );
  testWidgets(
    'hiding previews after posting forces review for an earlier action',
    (tester) => checkDisconnectedNotification(
      tester,
      review: false,
      hidePreviewsAfterPosting: true,
    ),
  );
  testWidgets(
    'offline review stays on one surface with explicit status',
    (tester) => checkDisconnectedNotification(tester, review: true),
  );
}
