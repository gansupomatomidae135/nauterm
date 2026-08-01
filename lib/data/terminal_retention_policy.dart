import 'package:flutter/foundation.dart';

import 'nauterm_data_store.dart';

@immutable
class TerminalRetentionPlan {
  const TerminalRetentionPlan({
    this.expiredLogIds = const {},
    this.oversizedLogIds = const {},
    this.capacityLogIds = const [],
  });

  final Set<String> expiredLogIds;
  final Set<String> oversizedLogIds;
  final List<String> capacityLogIds;

  Set<String> get deletedLogIds => {...expiredLogIds, ...capacityLogIds};
}

TerminalRetentionPlan planTerminalRetention({
  required Iterable<TerminalLogEntry> logs,
  required DateTime now,
  required int retentionDays,
  required int maxSessionBytes,
  required int maxTotalBytes,
  Set<String> activeLogIds = const {},
}) {
  final completed = logs
      .where((log) => log.endedAt != null && !activeLogIds.contains(log.id))
      .toList(growable: false);
  final cutoff = now.toUtc().subtract(Duration(days: retentionDays));
  final expired = {
    for (final log in completed)
      if (log.endedAt!.toUtc().isBefore(cutoff)) log.id,
  };
  final retained = completed
      .where((log) => !expired.contains(log.id))
      .toList(growable: false);
  final oversized = {
    for (final log in retained)
      if (log.captureFile.isNotEmpty && log.captureBytes > maxSessionBytes)
        log.id,
  };

  int effectiveBytes(TerminalLogEntry log) {
    if (oversized.contains(log.id)) return maxSessionBytes;
    return log.captureBytes;
  }

  var totalBytes = logs
      .where((log) => !expired.contains(log.id))
      .fold<int>(0, (total, log) => total + effectiveBytes(log));
  final oldestFirst = retained.toList(growable: false)
    ..sort(
      (left, right) => (left.endedAt ?? left.startedAt).compareTo(
        right.endedAt ?? right.startedAt,
      ),
    );
  final capacity = <String>[];
  for (final log in oldestFirst) {
    if (totalBytes <= maxTotalBytes) break;
    final bytes = effectiveBytes(log);
    if (bytes <= 0) continue;
    capacity.add(log.id);
    totalBytes -= bytes;
  }
  return TerminalRetentionPlan(
    expiredLogIds: Set.unmodifiable(expired),
    oversizedLogIds: Set.unmodifiable(oversized),
    capacityLogIds: List.unmodifiable(capacity),
  );
}
