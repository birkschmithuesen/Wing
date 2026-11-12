import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../tools/architecture/model.dart';
import '../tools/architecture/rules/domain_dependencies.dart' as domain;

void main() {
  late Directory root;
  late File source, manifest;
  void roles(String role) => manifest.writeAsStringSync(
    jsonEncode({
      'schema': 1,
      'files': {
        'lib/value.dart': {
          'role': role,
          'feature': 'fixture',
          'library': 'lib/value.dart',
        },
      },
    }),
  );
  Snapshot load() => Snapshot.load(root.path, manifest.path);

  setUp(() {
    root = Directory.systemTemp.createTempSync('wing-source-parsing-');
    source = File('${root.path}/lib/value.dart')..createSync(recursive: true);
    source.writeAsStringSync(
      "import 'dart:io'; class Value { int count = 1; }",
    );
    manifest = File('${root.path}/roles.json');
    roles('domain');
  });
  tearDown(() => root.deleteSync(recursive: true));

  test('unchanged trees are shared while roles and findings refresh', () async {
    await withSharedSourceParses(() async {
      final first = load();
      expect(domain.check(first), isNotEmpty);
      roles('utility');
      final second = load();
      expect(
        identical(
          first.sources['lib/value.dart']!.ast,
          second.sources['lib/value.dart']!.ast,
        ),
        isTrue,
      );
      expect(
        identical(
          first.sources['lib/value.dart'],
          second.sources['lib/value.dart'],
        ),
        isFalse,
      );
      expect(domain.check(second), isEmpty);
      roles('domain');
      expect(domain.check(load()), isNotEmpty);
    });
  });

  test(
    'same-size same-mtime source changes and repairs invalidate trees',
    () async {
      await withSharedSourceParses(() async {
        final first = load();
        final stamp = source.lastModifiedSync();
        source.writeAsStringSync(
          source.readAsStringSync().replaceFirst('count = 1', 'count = 2'),
        );
        source.setLastModifiedSync(stamp);
        final second = load();
        expect(
          identical(
            first.sources['lib/value.dart']!.ast,
            second.sources['lib/value.dart']!.ast,
          ),
          isFalse,
        );
        expect(
          second.sources['lib/value.dart']!.ast.toSource(),
          contains('count = 2'),
        );
        source.writeAsStringSync('class Value {');
        expect(load, throwsFormatException);
        source.writeAsStringSync('class Value {}');
        expect(
          load().sources['lib/value.dart']!.ast.toSource(),
          'class Value {}',
        );
      });
    },
  );

  test('file changes rebuild parts and dependency graphs', () async {
    await withSharedSourceParses(() async {
      source.writeAsStringSync("part 'value_part.dart'; class Value {}");
      final part = File('${root.path}/lib/value_part.dart')
        ..writeAsStringSync("part of 'value.dart'; class Member {}");
      final first = load();
      expect(first.partOwners['lib/value_part.dart'], ['lib/value.dart']);
      part.deleteSync();
      source.writeAsStringSync("import 'other.dart'; class Value {}");
      final other = File('${root.path}/lib/other.dart')
        ..writeAsStringSync('class Other {}');
      final second = load();
      expect(second.sources.containsKey('lib/value_part.dart'), isFalse);
      expect(second.partOwners, isEmpty);
      expect(second.graph['lib/value.dart'], contains('lib/other.dart'));
      other.deleteSync();
      expect(load().sources.containsKey('lib/other.dart'), isFalse);
    });
  });

  test('roots and completed batch scopes own separate parsed trees', () async {
    final original = load();
    final other = Directory.systemTemp.createTempSync(
      'wing-source-parsing-other-',
    );
    addTearDown(() => other.deleteSync(recursive: true));
    File('${other.path}/lib/value.dart')
      ..createSync(recursive: true)
      ..writeAsStringSync('class Different {}');
    File(
      '${other.path}/roles.json',
    ).writeAsStringSync(manifest.readAsStringSync());
    late Snapshot inside;
    await withSharedSourceParses(() async {
      inside = load();
      final alternate = Snapshot.load(other.path, '${other.path}/roles.json');
      expect(
        alternate.sources['lib/value.dart']!.ast.toSource(),
        'class Different {}',
      );
      expect(
        load().sources['lib/value.dart']!.ast.toSource(),
        original.sources['lib/value.dart']!.ast.toSource(),
      );
    });
    expect(
      identical(
        inside.sources['lib/value.dart']!.ast,
        load().sources['lib/value.dart']!.ast,
      ),
      isFalse,
    );
  });
}
