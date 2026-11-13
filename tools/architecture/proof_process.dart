import 'dart:async';
import 'dart:convert';
import 'dart:io';

final _proofScope = Object();

/// The SDK command used by fixture harnesses, including native dispatchers.
String get proofDartExecutable {
  final shared = Platform.environment['WING_TEST_ARCHITECTURE_COMMANDS'];
  if (shared == null) return Platform.resolvedExecutable;
  final descriptor = jsonDecode(File(shared).readAsStringSync()) as Map;
  return descriptor['dart'] as String;
}

/// Compile source guard commands once within a proof, never fixture verdicts.
/// Artifacts belong to this scope and are removed after its children finish.
Future<T> withProofProcesses<T>(
  Future<T> Function() action, {
  Directory? sourceRoot,
}) async {
  final processes = _ProofProcesses(sourceRoot ?? Directory.current);
  try {
    return await runZoned(action, zoneValues: {_proofScope: processes});
  } finally {
    await processes.close();
  }
}

/// Keep each original process result and its argument/diagnostic assertions.
/// Native compilation/execution and SDK analysis remain direct subprocesses.
Future<ProcessResult> runProofProcess(
  String executable,
  List<String> arguments,
) {
  final scope = Zone.current[_proofScope];
  if (scope is! _ProofProcesses) {
    return withProofProcesses(() => runProofProcess(executable, arguments));
  }
  return scope.run(executable, arguments);
}

/// Preserve streaming supervisor children and their inherited environment.
/// Callers drain both streams and await exit before releasing fixture roots.
Future<Process> startProofProcess(
  String executable,
  List<String> arguments, {
  Map<String, String>? environment,
}) async {
  final scope = Zone.current[_proofScope];
  final root = scope is _ProofProcesses ? scope.root : Directory.current;
  final command = _sharedCommand(executable, arguments, root);
  final child = await Process.start(
    command?.$1 ?? executable,
    command?.$2 ?? arguments,
    workingDirectory: root.path,
    environment: environment,
  );
  if (scope is _ProofProcesses) {
    scope.children.add(child.exitCode);
  }
  return child;
}

(String, List<String>)? _sharedCommand(
  String executable,
  List<String> arguments,
  Directory root,
) {
  final shared = Platform.environment['WING_TEST_ARCHITECTURE_COMMANDS'];
  if (shared != null &&
      arguments.length >= 2 &&
      (arguments.first == 'run' || arguments.first.startsWith('--packages='))) {
    final descriptor = jsonDecode(File(shared).readAsStringSync()) as Map;
    final source = File.fromUri(root.uri.resolveUri(Uri.file(arguments[1])));
    var boundPackages = arguments.first == 'run';
    if (!boundPackages) {
      final configured = arguments.first.substring('--packages='.length);
      final uri = Uri.parse(configured);
      final config = uri.scheme == 'file'
          ? File.fromUri(uri)
          : File.fromUri(root.uri.resolveUri(Uri.file(configured)));
      boundPackages = config.absolute.path == descriptor['package_config'];
    }
    if (boundPackages &&
        File(executable).absolute.path == descriptor['dart'] &&
        (descriptor['commands'] as List).contains(source.path)) {
      if (!File(descriptor['snapshot'] as String).existsSync()) {
        throw StateError('The run-owned architecture artifact is missing.');
      }
      return (
        descriptor['runtime'] as String,
        <String>[
          descriptor['snapshot'] as String,
          source.path,
          ...arguments.skip(2),
        ],
      );
    }
  }
  return null;
}

class _ProofProcesses {
  _ProofProcesses(this.root);

  final Directory root;
  final _programs = <(String, String), _Program>{};
  final _pending = <Future<ProcessResult>>{};
  final children = <Future<int>>[];
  Directory? _scratch;

  Future<ProcessResult> run(String executable, List<String> arguments) {
    final operation = _run(executable, arguments);
    _pending.add(operation);
    operation.then<void>(
      (_) => _pending.remove(operation),
      onError: (Object _, StackTrace _) => _pending.remove(operation),
    );
    return operation;
  }

  Future<ProcessResult> _run(String executable, List<String> arguments) async {
    final shared = _sharedCommand(executable, arguments, root);
    if (shared != null) {
      return Process.run(shared.$1, shared.$2, workingDirectory: root.path);
    }
    final executableName = File(executable).uri.pathSegments.last;
    if (!{'dart', 'dart.exe'}.contains(executableName) ||
        arguments.length < 2 ||
        arguments.first != 'run') {
      return Process.run(executable, arguments, workingDirectory: root.path);
    }
    final source = File.fromUri(root.uri.resolveUri(Uri.file(arguments[1])));
    final rules = root.uri.resolve('tools/architecture/rules/').toFilePath();
    if (!source.path.startsWith(rules) || !source.path.endsWith('.dart')) {
      return Process.run(executable, arguments, workingDirectory: root.path);
    }
    final program = _programs.putIfAbsent((
      executable,
      source.path,
    ), _Program.new);
    // Three source exits are already a minimal CLI proof. Avoid adding a
    // compilation and more processes when there are no repeated cases to save.
    if (program.invocations++ < 3) {
      final result = await Process.run(
        executable,
        arguments,
        workingDirectory: root.path,
      );
      program.sourceExits.add(result.exitCode);
      return result;
    }
    final kernel = await (program.kernel ??= _compile(executable, source));
    final result = await Process.run(executable, [
      kernel.path,
      ...arguments.skip(2),
    ], workingDirectory: root.path);
    if (program.sourceExits.add(result.exitCode)) {
      // Each command retains actual source-launch controls for every observed
      // exit, including INPUT2/invalid-SDK paths. Repeated cases reuse only IR.
      final sourceResult = await Process.run(
        executable,
        arguments,
        workingDirectory: root.path,
      );
      if (sourceResult.exitCode != result.exitCode) {
        throw StateError(
          '${source.path}: source/kernel exit disagreement: '
          '${sourceResult.exitCode}/${result.exitCode}\n'
          '${sourceResult.stdout}${sourceResult.stderr}\n'
          '${result.stdout}${result.stderr}',
        );
      }
      return sourceResult;
    }
    return result;
  }

  Future<File> _compile(String executable, File source) async {
    _scratch ??= Directory.systemTemp.createTempSync('wing-proof-commands-');
    final directory = _scratch!.createTempSync('command-');
    final kernel = File('${directory.path}/command.dill');
    final compilation = await Process.run(executable, [
      'compile',
      'kernel',
      '--packages=${root.path}/.dart_tool/package_config.json',
      source.path,
      '-o',
      kernel.path,
    ], workingDirectory: root.path);
    if (compilation.exitCode != 0 || !kernel.existsSync()) {
      throw StateError(
        '${source.path}: proof CLI compilation failed\n'
        '${compilation.stdout}${compilation.stderr}',
      );
    }
    return kernel;
  }

  Future<void> close() async {
    await Future.wait([
      for (final operation in _pending)
        operation.then<void>((_) {}, onError: (Object _, StackTrace _) {}),
    ]);
    await Future.wait(children);
    _scratch?.deleteSync(recursive: true);
  }
}

class _Program {
  var invocations = 0;
  Future<File>? kernel;
  final sourceExits = <int>{};
}
