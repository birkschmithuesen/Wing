import 'dart:io';
import 'package:wing/core/models/settings_edit.dart';

void main() {
  var passed = 0;
  void check(String name, bool condition) {
    if (!condition) throw StateError(name);
    passed++;
  }

  for (final pair in [
    ('0.29', 2, '29'),
    ('29', -2, '0.29'),
    ('0.8123456789', 2, '81.23456789'),
    ('.5', -2, '0.005'),
    ('1e-3', 2, '0.1'),
    ('1e999999999999999999999999', 2, '1e999999999999999999999999'),
  ]) {
    check(
      'exact decimal ${pair.$1}',
      shiftDecimal(pair.$1, pair.$2) == pair.$3,
    );
  }
  final percent = compressionFields[1];
  check(
    'scientific displayed percent is canonical fraction',
    percent.parse('8.123456789e1') == .8123456789,
  );
  check(
    'nonfinite percentage rejected',
    percent.validate(percent.parse('Infinity')) != null,
  );
  check(
    'range policy retained',
    percent.validate(percent.parse('101')) == 'Maximum: 100%',
  );
  final choices = ['one'];
  final field = AdminField(
    'choice',
    'Choice',
    AdminFieldKind.choice,
    choices: choices,
  );
  choices.add('later');
  check(
    'field metadata freezes mutable caller choices',
    field.choices.length == 1 && field.choices.single == 'one',
  );
  final baseline = <String, Object?>{
    'budget': 20,
    'list': ['one'],
    'other': true,
  };
  final desired = <String, Object?>{'budget': 30};
  final intent = SettingsEditIntent(baseline: baseline, desired: desired);
  baseline['budget'] = 999;
  desired['budget'] = 888;
  (baseline['list'] as List).add('outside edit');
  check(
    'intent freezes opening and desired inputs',
    intent.baseline['budget'] == 20 && intent.desired['budget'] == 30,
  );
  check(
    'intent detaches nested baseline collections',
    sameSetting(intent.baseline['list'], ['one']),
  );
  final updates = intent.resolve({'budget': 20, 'other': false}).updates;
  check(
    'independent server fields never enter sparse write',
    updates.length == 1 && updates['budget'] == 30,
  );
  check(
    'already converged desired values are read-only',
    intent.resolve({'budget': 30}).updates.isEmpty,
  );
  check(
    'same-field external edit is a conflict',
    intent.resolve({'budget': 40}).conflicts['budget'] == 40,
  );
  final speech = SettingsEditIntent(
    baseline: {'tts.provider': 'captured', 'tts.voice': 'old'},
    desired: {'tts.voice': 'new'},
    invariants: {'tts.provider'},
  );
  check(
    'explicit provider invariant is not a guessed route',
    speech
        .resolve({
          'tts': {'provider': 'other', 'voice': 'old'},
        })
        .conflicts
        .containsKey('tts.provider'),
  );
  check(
    'lines normalize at owner boundary',
    sameSetting(
      AdminField(
        'lines',
        'Lines',
        AdminFieldKind.lines,
      ).parse(' one \n\n two '),
      ['one', 'two'],
    ),
  );
  try {
    SettingsEditIntent(
      baseline: {'field': null},
      desired: {
        'field': {'unbounded': 'map'},
      },
    );
    throw StateError('Nested arbitrary settings writes were accepted');
  } on ArgumentError {
    passed++;
  }
  for (final value in [double.nan, double.infinity]) {
    try {
      SettingsEditIntent(baseline: {'field': null}, desired: {'field': value});
      throw StateError('Nonfinite settings intent was accepted');
    } on ArgumentError {
      passed++;
    }
  }
  stdout.writeln('Settings intent/codec: $passed checks passed');
}
