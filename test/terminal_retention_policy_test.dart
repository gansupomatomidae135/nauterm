import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nauterm/data/nauterm_data_store.dart';
import 'package:nauterm/data/terminal_recording_store.dart';
import 'package:nauterm/data/terminal_retention_policy.dart';

void main() {
  TerminalLogEntry log({
    required String id,
    required DateTime startedAt,
    DateTime? endedAt,
    int captureBytes = 0,
  }) {
    return TerminalLogEntry(
      id: id,
      title: id,
      captureFile: captureBytes == 0 ? '' : '$id.ntrcap',
      captureBytes: captureBytes,
      startedAt: startedAt,
      endedAt: endedAt,
    );
  }

  test(
    'retention expires old logs, trims large captures, and frees capacity',
    () {
      final now = DateTime.utc(2026, 7, 26);
      final plan = planTerminalRetention(
        logs: [
          log(
            id: 'expired',
            startedAt: now.subtract(const Duration(days: 41)),
            endedAt: now.subtract(const Duration(days: 40)),
            captureBytes: 10,
          ),
          log(
            id: 'oldest-retained',
            startedAt: now.subtract(const Duration(days: 3)),
            endedAt: now.subtract(const Duration(days: 2)),
            captureBytes: 80,
          ),
          log(
            id: 'oversized',
            startedAt: now.subtract(const Duration(days: 2)),
            endedAt: now.subtract(const Duration(days: 1)),
            captureBytes: 120,
          ),
          log(id: 'active', startedAt: now, captureBytes: 70),
        ],
        now: now,
        retentionDays: 30,
        maxSessionBytes: 100,
        maxTotalBytes: 200,
        activeLogIds: const {'active'},
      );

      expect(plan.expiredLogIds, {'expired'});
      expect(plan.oversizedLogIds, {'oversized'});
      expect(plan.capacityLogIds, ['oldest-retained']);
      expect(plan.deletedLogIds, {'expired', 'oldest-retained'});
    },
  );

  test('tail compaction keeps the newest bytes', () {
    final retained = retainTerminalCaptureTailChunks([
      Uint8List.fromList([1, 2, 3, 4, 5]),
      Uint8List.fromList([6, 7, 8, 9, 10]),
    ], 29 + 85 + 29 + 7);

    expect(retained.expand((chunk) => chunk), [4, 5, 6, 7, 8, 9, 10]);
  });

  test('capacity cleanup never selects an active session', () {
    final now = DateTime.utc(2026, 7, 26);
    final plan = planTerminalRetention(
      logs: [log(id: 'active', startedAt: now, captureBytes: 500)],
      now: now,
      retentionDays: 30,
      maxSessionBytes: 100,
      maxTotalBytes: 10,
      activeLogIds: const {'active'},
    );

    expect(plan.deletedLogIds, isEmpty);
    expect(plan.oversizedLogIds, isEmpty);
  });

  test('encrypted capture compaction rewrites a valid tail', () async {
    final directory = await Directory.systemTemp.createTemp(
      'nauterm-retention-',
    );
    try {
      final store = TerminalLogCaptureStore(directory);
      final writer = await store.openWriter('tail-capture');
      writer.add(Uint8List.fromList(utf8.encode('first-')));
      writer.add(Uint8List.fromList(utf8.encode('latest')));
      await writer.close();

      final compacted = await store.retainTail(
        logId: 'tail-capture',
        captureFile: store.captureFileName('tail-capture'),
        maxBytes: 29 + 85 + 29 + 6,
      );
      final decoded = <int>[];
      await for (final chunk in store.readDecryptedChunks(
        logId: 'tail-capture',
        captureFile: compacted.fileName,
      )) {
        decoded.addAll(chunk);
      }

      expect(utf8.decode(decoded), 'latest');
      expect(compacted.bytes, lessThanOrEqualTo(29 + 85 + 29 + 6));
      expect(compacted.sha256, isNotEmpty);
    } finally {
      await directory.delete(recursive: true);
    }
  });
}
