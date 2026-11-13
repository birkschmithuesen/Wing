import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../tools/architecture/dart_sdk.dart';
import '../tools/architecture/proof_process.dart';

void main() {
  final sdk = dartSdkPath(Directory.current.path);
  late Directory root;
  late File source;

  setUp(() {
    root = Directory.systemTemp.createTempSync('wing-proof-process-test-');
    source = File('${root.path}/tools/architecture/rules/probe.dart');
    source.parent.createSync(recursive: true);
    final config = File('${root.path}/.dart_tool/package_config.json');
    config.parent.createSync();
    config.writeAsStringSync('{"configVersion":2,"packages":[]}');
  });

  tearDown(() => root.deleteSync(recursive: true));

  test(
    'streaming children retain environment, scratch root and exit status',
    () async {
      source.writeAsStringSync(r'''
import 'dart:convert';
import 'dart:io';
void main(List<String> args) {
  stdout.writeln(jsonEncode({
    'arguments': args,
    'cwd': Directory.current.path,
    'scratch': Directory.systemTemp.path,
    'child': Platform.environment['WING_PROOF_CHILD'],
    'inherited': Platform.environment['PATH'],
  }));
  stderr.writeln('retained input diagnostic');
  exitCode = 2;
}
''');
      await withProofProcesses(() async {
        final child = await startProofProcess(
          '$sdk/bin/dart',
          ['run', source.path, 'fresh child argument'],
          environment: {'TMPDIR': root.path, 'WING_PROOF_CHILD': '1'},
        );
        final streams = await Future.wait([
          child.stdout.transform(utf8.decoder).join(),
          child.stderr.transform(utf8.decoder).join(),
        ]);
        expect(await child.exitCode, 2);
        final output = jsonDecode(streams.first) as Map;
        expect(output['arguments'], ['fresh child argument']);
        expect(output['cwd'], root.path);
        expect(output['scratch'], root.path);
        expect(output['child'], '1');
        expect(output['inherited'], Platform.environment['PATH']);
        expect(streams.last, contains('retained input diagnostic'));
      }, sourceRoot: root);
    },
  );

  test('an exported proof helper owns an independent command scope', () async {
    source.writeAsStringSync('''
import 'dart:io';
void main(List<String> args) {
  stdout.writeln(args.single);
  exitCode = 1;
}
''');
    final result = await runProofProcess('$sdk/bin/dart', [
      'run',
      source.path,
      'independent invocation',
    ]);
    expect(result.exitCode, 1);
    expect(result.stdout, contains('independent invocation'));
  });

  test(
    'retains source exits, fresh inputs and owned artifact cleanup',
    () async {
      source.writeAsStringSync(r'''
import 'dart:convert';
import 'dart:io';
void main(List<String> args) {
  final status = int.parse(args[0]);
  File(args[1]).writeAsStringSync(
    '${Platform.script.path.endsWith('.dart') ? 'source' : 'kernel'}:$status\n',
    mode: FileMode.append,
  );
  stdout.writeln(jsonEncode({
    'args': args,
    'cwd': Directory.current.path,
    'script': Platform.script.toFilePath(),
  }));
  stderr.writeln('diagnostic:$status:${args[2]}');
  exitCode = status;
}
''');
      final log = File('${root.path}/launches.txt');
      late String kernel;
      await withProofProcesses(() async {
        for (var index = 0; index < 6; index++) {
          final status = [1, 1, 0, 0, 2, 2][index];
          final arguments = ['$status', log.path, 'input:$index'];
          final result = await runProofProcess('$sdk/bin/dart', [
            'run',
            source.path,
            ...arguments,
          ]);
          expect(result.exitCode, status);
          expect(result.stderr, contains('diagnostic:$status:input:$index'));
          final output = jsonDecode(result.stdout as String) as Map;
          expect(output['args'], arguments);
          expect(output['cwd'], root.path);
          if (index == 3) {
            kernel = output['script'] as String;
            expect(kernel, endsWith('.dill'));
            expect(File(kernel).existsSync(), isTrue);
          }
        }
      }, sourceRoot: root);
      expect(File(kernel).existsSync(), isFalse);
      final launches = log.readAsLinesSync();
      expect(
        launches.where((line) => line.startsWith('kernel:')),
        hasLength(3),
      );
      expect(launches.where((line) => line.startsWith('source:')), [
        'source:1',
        'source:1',
        'source:0',
        'source:2',
      ]);
    },
  );

  test('source and kernel exit disagreement fails closed', () async {
    source.writeAsStringSync(r'''
import 'dart:io';
void main() {
  exitCode = Platform.script.path.endsWith('.dart') ? 1 : 0;
}
''');
    await expectLater(
      withProofProcesses(() async {
        for (var index = 0; index < 4; index++) {
          await runProofProcess('$sdk/bin/dart', ['run', source.path]);
        }
      }, sourceRoot: root),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'failure',
          contains('source/kernel exit disagreement'),
        ),
      ),
    );
  });

  test('compiler failure cannot become a successful guard result', () async {
    source.writeAsStringSync('void main( {');
    await expectLater(
      withProofProcesses(() async {
        for (var index = 0; index < 4; index++) {
          final result = await runProofProcess('$sdk/bin/dart', [
            'run',
            source.path,
          ]);
          expect(result.exitCode, isNot(0));
        }
      }, sourceRoot: root),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'failure',
          contains('proof CLI compilation failed'),
        ),
      ),
    );
  });
}
