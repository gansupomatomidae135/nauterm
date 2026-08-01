import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nauterm/data/nauterm_paths.dart';
import 'package:nauterm/data/sync_service.dart';

void main() {
  test(
    'automatic sync does not run immediately on application start',
    () async {
      final paths = await _pathsWithConfig(
        automatic: true,
        strategy: 'local_wins',
      );
      addTearDown(() => paths.configDirectory.delete(recursive: true));
      final called = Completer<String>();
      final service = SyncService(
        paths,
        syncNow: (strategy) async => called.complete(strategy),
      );

      service.start();

      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(called.isCompleted, isFalse);
      await service.close();
    },
  );

  test('config changes reschedule without syncing immediately', () async {
    final paths = await _pathsWithConfig(automatic: false);
    addTearDown(() => paths.configDirectory.delete(recursive: true));
    final called = Completer<void>();
    final service = SyncService(paths, syncNow: (_) async => called.complete());
    service.start();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(called.isCompleted, isFalse);

    await paths.configFile.writeAsString(
      '{"schemaVersion":1,"sync":{"mergeStrategy":"smart_merge",'
      '"automatic":true,"interval":3600000}}\n',
    );
    service.preferencesChanged();

    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(called.isCompleted, isFalse);
    await service.close();
  });
}

Future<NautermPaths> _pathsWithConfig({
  required bool automatic,
  String strategy = 'smart_merge',
}) async {
  final directory = await Directory.systemTemp.createTemp(
    'nauterm_sync_service_test_',
  );
  final paths = NautermPaths(
    configDirectory: directory,
    dataDirectory: directory,
  );
  await paths.ensureCreated();
  await paths.configFile.writeAsString(
    '{"schemaVersion":1,"sync":{"mergeStrategy":"$strategy",'
    '"automatic":$automatic,"interval":3600000}}\n',
  );
  return paths;
}
