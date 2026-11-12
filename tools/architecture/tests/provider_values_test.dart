import 'dart:io';
import 'package:wing/core/models/provider_inventory.dart';
import 'package:wing/core/models/provider_device_sign_in.dart';

void main() {
  var checks = 0;
  void check(bool result) {
    if (!result) throw StateError('Provider value contract failed');
    checks++;
  }

  final now = DateTime.utc(2026, 10, 4);
  final data = <String, dynamic>{
    'session_id': 'owned',
    'flow': 'device_code',
    'user_code': 'fixture-code',
    'verification_url': 'https://example.invalid/sign-in',
    'expires_in': 999999,
    'poll_interval': 1,
  };
  check(ProviderDeviceSession.returnedIdentity(data) == 'owned');
  check(
    ProviderDeviceSession.returnedIdentity({'session_id': 'owned'}) == 'owned',
  );
  for (final invalid in <Object?>[
    null,
    7,
    '',
    '   ',
    ' owned ',
    ['owned'],
  ]) {
    check(
      ProviderDeviceSession.returnedIdentity({'session_id': invalid}) == null,
    );
  }
  check(ProviderDeviceSession.returnedIdentity({'id': 'owned'}) == null);
  for (final invalid in <Object?>[
    null,
    7,
    '',
    '   ',
    ' owned ',
    ['owned'],
  ]) {
    try {
      ProviderDeviceSession.fromStart({...data, 'session_id': invalid}, now);
      throw StateError('Malformed canonical identity accepted for display');
    } on FormatException {
      checks++;
    }
  }
  final session = ProviderDeviceSession.fromStart(data, now);
  check(session.deadline.difference(now) == const Duration(minutes: 15));
  check(session.pollInterval == const Duration(seconds: 3));
  for (final field in [
    'session_id',
    'flow',
    'user_code',
    'verification_url',
    'expires_in',
    'poll_interval',
  ]) {
    final invalid = {...data}..remove(field);
    try {
      ProviderDeviceSession.fromStart(invalid, now);
      throw StateError('Missing canonical field accepted');
    } on FormatException {
      checks++;
    }
  }
  for (final url in [
    'file:///tmp/file',
    'javascript:alert(1)',
    'https:///missing-host',
  ]) {
    try {
      ProviderDeviceSession.fromStart({...data, 'verification_url': url}, now);
      throw StateError('Unsafe URL accepted');
    } on FormatException {
      checks++;
    }
  }
  for (final interval in [0, -1, 1.5, '5']) {
    try {
      ProviderDeviceSession.fromStart({
        ...data,
        'poll_interval': interval,
      }, now);
      throw StateError('Invalid interval accepted');
    } on FormatException {
      checks++;
    }
  }
  check(
    session.statusFromPoll({'session_id': 'owned', 'status': 'approved'}) ==
        ProviderDeviceStatus.approved,
  );
  for (final poll in [
    {'session_id': 'other', 'status': 'approved'},
    {'status': 'approved'},
    {'session_id': 'owned', 'status': 'unknown'},
    {'session_id': 'owned', 'status': 'failed'},
  ]) {
    try {
      session.statusFromPoll(poll);
      throw StateError('Unsupported poll identity/status accepted');
    } on FormatException {
      checks++;
    }
  }
  final metadata = <String, dynamic>{
    'is_set': true,
    'channel_managed': false,
    'category': 'api_keys',
    'provider_label': 'Shared service',
    'value': 'synthetic-secret',
    'redacted_value': 'synthetic-preview',
  };
  final key = ProviderEnvironmentField.fromWire('SHARED_API_KEY', metadata);
  metadata['is_set'] = false;
  check(key.isSet);
  check(key.editable);
  check(key.label == 'Shared service');
  check(key.matches('', catalog: false));
  check(
    !ProviderEnvironmentField.fromWire('CHANNEL_KEY', {
      ...metadata,
      'channel_managed': true,
    }).editable,
  );
  check(
    !ProviderEnvironmentField.fromWire('CUSTOM_KEY', {
      ...metadata,
      'category': 'custom',
    }).editable,
  );
  for (final field in [
    'is_set',
    'channel_managed',
    'category',
    'provider_label',
  ]) {
    try {
      ProviderEnvironmentField.fromWire('KEY', {...metadata}..remove(field));
      throw StateError('Unknown metadata accepted');
    } on FormatException {
      checks++;
    }
  }
  stdout.writeln('Provider values: $checks checks passed');
}
