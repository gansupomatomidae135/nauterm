import 'dart:io';

import 'nauterm_data_store.dart';

/// Persistent, display-oriented command history for snippets.
///
/// Each row is `millisecondsSinceEpoch;command`.  It intentionally contains
/// no host credentials or JSON metadata; connection-specific, non-deduped
/// history stays in memory on the active terminal controller.
class ShellHistoryFileStore {
  const ShellHistoryFileStore(this.file);

  static const int defaultLimit = 10000;

  final File file;

  Future<List<ShellHistoryEntry>> read({int limit = defaultLimit}) async {
    if (!await file.exists()) {
      return const [];
    }
    final text = await file.readAsString();
    final entries = <ShellHistoryEntry>[];
    for (final line in text.split('\n')) {
      final separator = line.indexOf(';');
      if (separator <= 0) continue;
      final timestamp = int.tryParse(line.substring(0, separator));
      final command = _unescape(line.substring(separator + 1)).trim();
      if (timestamp == null || command.isEmpty) continue;
      entries.add(
        ShellHistoryEntry(
          sourceId: 'file:$timestamp:$command',
          command: command,
          createdAt: DateTime.fromMillisecondsSinceEpoch(timestamp),
        ),
      );
    }
    return _dedupeNewest(entries, limit: limit);
  }

  Future<List<ShellHistoryEntry>> append(
    ShellHistoryEntry entry, {
    int limit = defaultLimit,
  }) async {
    return merge([entry], limit: limit);
  }

  Future<void> clear() async {
    if (await file.exists()) {
      await file.delete();
    }
  }

  Future<List<ShellHistoryEntry>> merge(
    Iterable<ShellHistoryEntry> entries, {
    int limit = defaultLimit,
  }) async {
    final current = await read(limit: limit);
    final incoming = entries.toList(growable: false).reversed;
    final updated = _dedupeNewest([...incoming, ...current], limit: limit);
    await file.parent.create(recursive: true);
    final rows = [
      for (final item in updated)
        '${(item.createdAt ?? DateTime.now()).millisecondsSinceEpoch};${_escape(item.command)}',
    ].join('\n');
    await file.writeAsString('$rows\n', flush: true);
    return updated;
  }

  List<ShellHistoryEntry> _dedupeNewest(
    Iterable<ShellHistoryEntry> entries, {
    required int limit,
  }) {
    final seen = <String>{};
    final result = <ShellHistoryEntry>[];
    for (final entry in entries) {
      final command = entry.command.trim();
      if (command.isEmpty || !seen.add(command)) continue;
      result.add(entry);
      if (result.length == limit) break;
    }
    return result;
  }

  String _escape(String value) =>
      value.replaceAll('\\', '\\\\').replaceAll('\n', '\\n');

  String _unescape(String value) {
    final output = StringBuffer();
    var escaped = false;
    for (final codeUnit in value.codeUnits) {
      if (escaped) {
        output.write(codeUnit == 0x6e ? '\n' : String.fromCharCode(codeUnit));
        escaped = false;
      } else if (codeUnit == 0x5c) {
        escaped = true;
      } else {
        output.writeCharCode(codeUnit);
      }
    }
    if (escaped) output.write('\\');
    return output.toString();
  }
}
