import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:wing/porter_wake/porter_wake_payload.dart';

List<int> bytes(String s) => utf8.encode(s);

void main() {
  test('a v1 porter_wake push yields its notice id', () {
    final p = PorterWakePayload.parse(
      bytes('{"v":1,"type":"porter_wake","notice_id":"n-3f2a9c1b7d4e"}'),
    );
    expect(p?.noticeId, 'n-3f2a9c1b7d4e');
  });

  test('unknown type, v2, bad id, non-JSON and non-UTF-8 are ignored', () {
    for (final raw in [
      bytes('{"v":1,"type":"other","notice_id":"n-3f2a9c1b7d4e"}'),
      bytes('{"v":2,"type":"porter_wake","notice_id":"n-3f2a9c1b7d4e"}'),
      bytes('{"v":"1","type":"porter_wake","notice_id":"n-3f2a9c1b7d4e"}'),
      bytes('{"v":1,"type":"porter_wake","notice_id":"../settings"}'),
      bytes('{"v":1,"type":"porter_wake"}'),
      bytes('[1,2]'),
      bytes('not json'),
      [0xff, 0xfe, 0x00],
      <int>[],
    ]) {
      expect(PorterWakePayload.parse(raw), isNull, reason: '$raw');
    }
  });

  test('extra fields do not matter', () {
    final p = PorterWakePayload.parse(
      bytes('{"v":1,"type":"porter_wake","notice_id":"n-000000000000","x":1}'),
    );
    expect(p?.noticeId, 'n-000000000000');
  });
}
