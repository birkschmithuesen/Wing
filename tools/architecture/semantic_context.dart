import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:analyzer/src/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/src/dart/analysis/byte_store.dart';
import 'package:analyzer/src/dart/analysis/file_byte_store.dart';
import 'package:analyzer/file_system/overlay_file_system.dart';
import 'package:analyzer/file_system/physical_file_system.dart';
import 'package:crypto/crypto.dart';

var _storeSequence = 0;
final _batchNamespace = Object();

/// Share analyzer summaries within one source-linter batch, never rule results.
/// The analyzer still validates source, dependency and option changes per read.
Future<T> withSharedAnalysisSummaries<T>(Future<T> Function() action) =>
    runZoned(action, zoneValues: {_batchNamespace: 'commit-batch'});

/// Standard analyzer summary storage, never rule results. Source, dependency,
/// language/options and summary-version validation remain analyzer-owned.
/// SDK experiments are applied only for guards that explicitly require them;
/// other callers retain the checkout's discovered analysis options unchanged.
/// The installed analyzer's public collection API has no byteStore parameter.
AnalysisContextCollectionImpl semanticContextCollection({
  required String root,
  required String sdk,
  required List<String> includedPaths,
  required String cacheNamespace,
  bool enableSdkExperiments = true,
}) {
  root = Directory(root).resolveSymbolicLinksSync();
  final config = File('$root/.dart_tool/package_config.json');
  final binding = sha256.convert(
    utf8.encode(
      jsonEncode([
        root,
        enableSdkExperiments,
        Directory(sdk).resolveSymbolicLinksSync(),
        File('$sdk/version').readAsStringSync(),
        File('$sdk/lib/libraries.json').readAsStringSync(),
        config.existsSync() ? config.readAsStringSync() : null,
        if (File('$root/analysis_options.yaml').existsSync())
          File('$root/analysis_options.yaml').readAsStringSync(),
      ]),
    ),
  );
  // Independent production guards inspect the same checkout during complete
  // host verification. Share only analyzer-validated summaries for that root;
  // fixture roots retain their individual namespaces and mutation controls.
  final commands = Platform.environment['WING_TEST_ARCHITECTURE_COMMANDS'];
  final productionBatch =
      commands != null &&
      (jsonDecode(File(commands).readAsStringSync()) as Map)['root'] == root;
  final namespace =
      Zone.current[_batchNamespace] ??
      (productionBatch ? 'commit-batch' : cacheNamespace);
  final cache = Directory('$root/.dart_tool/architecture/$namespace/$binding');
  cache.createSync(recursive: true);
  // The pinned analyzer ignores collection enabledExperiments when discovering
  // options normally. Preserve that discovery and all physical options bytes.
  final provider = OverlayResourceProvider(PhysicalResourceProvider.INSTANCE);
  final optionsPath = '$root/analysis_options.yaml';
  var options = File(optionsPath).existsSync()
      ? File(optionsPath).readAsStringSync()
      : '';
  if (enableSdkExperiments && options.contains('enable-experiment:')) {
    throw const FormatException('Explicit experiment review required');
  }
  const header = 'analyzer:\n';
  const flags = '  enable-experiment:\n    - private-named-parameters\n';
  if (enableSdkExperiments && options.startsWith(header)) {
    options = '$header$flags${options.substring(header.length)}';
  } else if (enableSdkExperiments && options.contains('\n$header')) {
    options = options.replaceFirst('\n$header', '\n$header$flags');
  } else if (enableSdkExperiments) {
    options = '$options\n$header$flags';
  }
  provider.setOverlay(optionsPath, content: options, modificationStamp: 0);
  return AnalysisContextCollectionImpl(
    includedPaths: includedPaths,
    resourceProvider: provider,
    sdkPath: sdk,
    byteStore: SynchronousSummaryByteStore(
      cache.path,
      tempNameSuffix: '$pid-${Isolate.current.hashCode}-${_storeSequence++}',
    ),
  );
}

/// FileByteStore queues writes beyond context disposal. Fixture roots must be
/// deletable immediately after disposal, so complete each atomic write here.
/// The SDK's reader/validator still own the on-disk summary format.
class SynchronousSummaryByteStore implements ByteStore {
  SynchronousSummaryByteStore(this.path, {required this.tempNameSuffix})
    : reader = FileByteStore(path);

  final String path;
  final String tempNameSuffix;
  final FileByteStore reader;
  final validator = FileByteStoreValidator();

  @override
  Uint8List? get(String key) => reader.get(key);

  @override
  Uint8List putGet(String key, Uint8List bytes) {
    // These are the SDK store's accepted sharded keys.
    if (key.length <= 2 || key[0] == '.' || key[1] == '.') return bytes;
    final shard = Directory('$path/${key.substring(0, 2)}');
    shard.createSync(recursive: true);
    final temporary = File('$path/$key-temp-$tempNameSuffix');
    try {
      temporary.writeAsBytesSync(validator.wrapData(bytes));
      temporary.renameSync('${shard.path}/$key');
    } finally {
      if (temporary.existsSync()) temporary.deleteSync();
    }
    return bytes;
  }

  @override
  void release(Iterable<String> keys) => reader.release(keys);
}
