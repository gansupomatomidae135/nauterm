import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import 'terminal_models.dart';
import 'terminal_selection.dart';

@immutable
class TerminalOpenTarget {
  const TerminalOpenTarget({
    required this.value,
    required this.uri,
    required this.selection,
    required this.localPath,
  });

  final String value;
  final Uri uri;
  final TerminalSelection selection;
  final bool localPath;
}

TerminalOpenTarget? terminalOpenTargetAt(
  TerminalSnapshot snapshot,
  TerminalCellPosition position, {
  required bool allowLocalPaths,
  String? commandPromptText,
  String? commandWorkingDirectory,
}) {
  final row = position.row.clamp(0, snapshot.rows - 1).toInt();
  final column = position.column.clamp(0, snapshot.columns - 1).toInt();
  final cell = snapshot.cellAt(row, column);
  if (cell.hyperlink.isNotEmpty) {
    final uri = _webUri(cell.hyperlink);
    if (uri != null) {
      var start = column;
      while (start > 0 &&
          snapshot.cellAt(row, start - 1).hyperlink == cell.hyperlink) {
        start--;
      }
      var end = column + 1;
      while (end < snapshot.columns &&
          snapshot.cellAt(row, end).hyperlink == cell.hyperlink) {
        end++;
      }
      return TerminalOpenTarget(
        value: cell.hyperlink,
        uri: uri,
        selection: _rowSelection(snapshot, row, start, end),
        localPath: false,
      );
    }
  }

  if (allowLocalPaths) {
    final semanticTarget =
        _promptPathTargetAt(snapshot, row, column) ??
        _longListingTargetAt(
          snapshot,
          row,
          column,
          commandPromptText: commandPromptText,
          commandWorkingDirectory: commandWorkingDirectory,
        ) ??
        _existingLocalSpanTargetAt(
          snapshot,
          row,
          column,
          commandPromptText: commandPromptText,
          commandWorkingDirectory: commandWorkingDirectory,
        );
    if (semanticTarget != null) {
      return semanticTarget;
    }
  }

  var start = column;
  while (start > 0 && !_targetSeparator(snapshot.cellAt(row, start - 1))) {
    start--;
  }
  var end = column + 1;
  while (end < snapshot.columns &&
      !_targetSeparator(snapshot.cellAt(row, end))) {
    end++;
  }
  while (start < end && _leadingPunctuation(snapshot.cellAt(row, start).text)) {
    start++;
  }
  while (end > start &&
      _trailingPunctuation(snapshot.cellAt(row, end - 1).text)) {
    end--;
  }
  if (start >= end || column < start || column >= end) {
    return null;
  }

  final value = _cellText(snapshot, row, start, end);
  final webUri = _webUri(value);
  if (webUri != null) {
    return TerminalOpenTarget(
      value: value,
      uri: webUri,
      selection: _rowSelection(snapshot, row, start, end),
      localPath: false,
    );
  }
  if (!allowLocalPaths) {
    return null;
  }

  final path = _resolveLocalPath(
    snapshot,
    row,
    value,
    commandPromptText: commandPromptText,
    commandWorkingDirectory: commandWorkingDirectory,
  );
  if (!_localPathExists(path)) {
    return null;
  }
  return TerminalOpenTarget(
    value: value,
    uri: Uri.file(path),
    selection: _rowSelection(snapshot, row, start, end),
    localPath: true,
  );
}

Future<void> openTerminalTarget(TerminalOpenTarget target) async {
  final value = target.localPath
      ? target.uri.toFilePath()
      : target.uri.toString();
  if (target.localPath &&
      await FileSystemEntity.type(value, followLinks: true) ==
          FileSystemEntityType.notFound) {
    return;
  }
  if (Platform.isMacOS) {
    await Process.start('open', [value], mode: ProcessStartMode.detached);
  } else if (Platform.isWindows) {
    if (target.localPath) {
      await Process.start('explorer.exe', [
        value,
      ], mode: ProcessStartMode.detached);
    } else {
      await Process.start('rundll32', [
        'url.dll,FileProtocolHandler',
        value,
      ], mode: ProcessStartMode.detached);
    }
  } else {
    await Process.start('xdg-open', [value], mode: ProcessStartMode.detached);
  }
}

TerminalSelection _rowSelection(
  TerminalSnapshot snapshot,
  int row,
  int start,
  int end,
) {
  final rowStart = (row - snapshot.displayOffset) * snapshot.columns;
  return TerminalSelection(start: rowStart + start, end: rowStart + end);
}

TerminalOpenTarget? _promptPathTargetAt(
  TerminalSnapshot snapshot,
  int row,
  int column,
) {
  final line = _cellText(snapshot, row, 0, snapshot.columns).trimRight();
  final match = _promptDirectoryMatch(line);
  final rawValue = match?.group(1);
  if (match == null || rawValue == null) {
    return null;
  }
  final value = rawValue.trimRight();
  final valueStart = match.start + match.group(0)!.lastIndexOf(rawValue);
  final start = _textIndexToColumn(snapshot, row, valueStart);
  final end = _textIndexToColumn(snapshot, row, valueStart + value.length);
  if (column < start || column >= end) {
    return null;
  }
  final path = _expandPromptDirectory(value);
  if (path == null || !_localPathExists(path)) {
    return null;
  }
  return TerminalOpenTarget(
    value: value,
    uri: Uri.file(path),
    selection: _rowSelection(snapshot, row, start, end),
    localPath: true,
  );
}

TerminalOpenTarget? _longListingTargetAt(
  TerminalSnapshot snapshot,
  int row,
  int column, {
  String? commandPromptText,
  String? commandWorkingDirectory,
}) {
  final line = _cellText(snapshot, row, 0, snapshot.columns).trimRight();
  final match = RegExp(
    r'^[bcdlps-][rwxStTs-]{9}[+@.]?\s+\d+\s+(?:\S+\s+){6}(.+?)\s*$',
  ).firstMatch(line);
  var value = match?.group(1);
  if (match == null || value == null) {
    return null;
  }
  final valueStart = match.start + match.group(0)!.lastIndexOf(value);
  final symlinkSeparator = value.indexOf(' -> ');
  if (symlinkSeparator >= 0) {
    value = value.substring(0, symlinkSeparator);
  }
  final start = _textIndexToColumn(snapshot, row, valueStart);
  final end = _textIndexToColumn(snapshot, row, valueStart + value.length);
  if (column < start || column >= end) {
    return null;
  }
  final decoded = _decodeShellPathCandidate(value);
  final path = _resolveLocalPath(
    snapshot,
    row,
    decoded,
    commandPromptText: commandPromptText,
    commandWorkingDirectory: commandWorkingDirectory,
  );
  if (!_localPathExists(path)) {
    return null;
  }
  return TerminalOpenTarget(
    value: decoded,
    uri: Uri.file(path),
    selection: _rowSelection(snapshot, row, start, end),
    localPath: true,
  );
}

TerminalOpenTarget? _existingLocalSpanTargetAt(
  TerminalSnapshot snapshot,
  int row,
  int column, {
  String? commandPromptText,
  String? commandWorkingDirectory,
}) {
  final runs = <({int start, int end})>[];
  var runStart = -1;
  for (var current = 0; current <= snapshot.columns; current++) {
    final blank =
        current == snapshot.columns ||
        snapshot.cellAt(row, current).text.trim().isEmpty;
    if (!blank && runStart < 0) {
      runStart = current;
    } else if (blank && runStart >= 0) {
      runs.add((start: runStart, end: current));
      runStart = -1;
    }
  }
  final clickedRun = runs.indexWhere(
    (run) => column >= run.start && column < run.end,
  );
  if (clickedRun < 0) {
    return null;
  }

  final candidates = <({int start, int end, int runCount})>[];
  for (
    var startRun = math.max(0, clickedRun - 7);
    startRun <= clickedRun;
    startRun++
  ) {
    for (
      var endRun = clickedRun;
      endRun < runs.length && endRun < startRun + 8;
      endRun++
    ) {
      candidates.add((
        start: runs[startRun].start,
        end: runs[endRun].end,
        runCount: endRun - startRun + 1,
      ));
    }
  }
  candidates.sort((left, right) => left.runCount.compareTo(right.runCount));

  for (final candidate in candidates) {
    final raw = _cellText(snapshot, row, candidate.start, candidate.end);
    if (raw.length > 256) {
      continue;
    }
    final value = _decodeShellPathCandidate(raw);
    if (value.isEmpty || value.startsWith('-')) {
      continue;
    }
    final path = _resolveLocalPath(
      snapshot,
      row,
      value,
      commandPromptText: commandPromptText,
      commandWorkingDirectory: commandWorkingDirectory,
    );
    if (!_localPathExists(path)) {
      continue;
    }
    return TerminalOpenTarget(
      value: value,
      uri: Uri.file(path),
      selection: _rowSelection(snapshot, row, candidate.start, candidate.end),
      localPath: true,
    );
  }
  return null;
}

int _textIndexToColumn(TerminalSnapshot snapshot, int row, int textIndex) {
  var consumed = 0;
  for (var column = 0; column < snapshot.columns; column++) {
    if (consumed >= textIndex) {
      return column;
    }
    final cell = snapshot.cellAt(row, column);
    if (!cell.wideCharSpacer && !cell.leadingWideCharSpacer) {
      consumed += cell.text.length;
    }
  }
  return snapshot.columns;
}

String _decodeShellPathCandidate(String value) {
  var decoded = value.trim();
  if (decoded.length >= 2 &&
      ((decoded.startsWith("'") && decoded.endsWith("'")) ||
          (decoded.startsWith('"') && decoded.endsWith('"')))) {
    decoded = decoded.substring(1, decoded.length - 1);
  }
  return decoded.replaceAllMapped(RegExp(r'\\(.)'), (match) => match.group(1)!);
}

bool _targetSeparator(TerminalCell cell) {
  if (cell.wideCharSpacer || cell.leadingWideCharSpacer) {
    return false;
  }
  final text = cell.text;
  return text.trim().isEmpty || '"\'`|'.contains(text);
}

bool _leadingPunctuation(String text) => '([{<'.contains(text);
bool _trailingPunctuation(String text) => '.,;:)]}>'.contains(text);

String _cellText(TerminalSnapshot snapshot, int row, int start, int end) {
  final result = StringBuffer();
  for (var column = start; column < end; column++) {
    final cell = snapshot.cellAt(row, column);
    if (!cell.wideCharSpacer && !cell.leadingWideCharSpacer) {
      result.write(cell.text);
    }
  }
  return result.toString();
}

Uri? _webUri(String value) {
  final uri = Uri.tryParse(value);
  if (uri == null ||
      !uri.hasAuthority ||
      (uri.scheme != 'http' && uri.scheme != 'https')) {
    return null;
  }
  return uri;
}

bool _localPathExists(String path) {
  try {
    return FileSystemEntity.typeSync(path, followLinks: true) !=
        FileSystemEntityType.notFound;
  } on FileSystemException {
    return false;
  }
}

String _resolveLocalPath(
  TerminalSnapshot snapshot,
  int row,
  String value, {
  String? commandPromptText,
  String? commandWorkingDirectory,
}) {
  var path = value;
  final lineSuffix = RegExp(r'^(.*?):\d+(?::\d+)?$').firstMatch(path);
  if (lineSuffix != null && !RegExp(r'^[A-Za-z]:[\\/]').hasMatch(path)) {
    path = lineSuffix.group(1)!;
  }
  final home =
      Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
  if (path == '~' && home != null) {
    return home;
  }
  if (path.startsWith('~/') && home != null) {
    return _joinPath(home, path.substring(2));
  }
  if (File(path).isAbsolute || Directory(path).isAbsolute) {
    return path;
  }
  final promptDirectory =
      commandWorkingDirectory ??
      (commandPromptText == null
          ? null
          : _promptDirectoryFromLine(commandPromptText));
  final visiblePromptDirectory = _promptDirectory(snapshot, row);
  return _joinPath(
    promptDirectory ?? visiblePromptDirectory ?? Directory.current.path,
    path,
  );
}

String? _promptDirectory(TerminalSnapshot snapshot, int row) {
  for (var candidate = row; candidate >= 0; candidate--) {
    final line = _cellText(
      snapshot,
      candidate,
      0,
      snapshot.columns,
    ).trimRight();
    final directory = _promptDirectoryFromLine(line);
    if (directory != null) {
      return directory;
    }
  }
  return null;
}

String? _promptDirectoryFromLine(String line) {
  final directory = _promptDirectoryMatch(line)?.group(1)?.trimRight();
  if (directory == null || directory.isEmpty) {
    return null;
  }
  return _expandPromptDirectory(directory);
}

RegExpMatch? _promptDirectoryMatch(String line) {
  return RegExp(r'^\[.*\s([~/][^\]]*)\][#$%>](?:\s|$)').firstMatch(line) ??
      RegExp(r':(~|/[^$%#>]*?)\s*[#$%>](?:\s|$)').firstMatch(line) ??
      RegExp(r'^PS\s+(.+?)>(?:\s|$)').firstMatch(line);
}

String? _expandPromptDirectory(String directory) {
  if (directory == '~' || directory.startsWith('~/')) {
    final home =
        Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
    if (home == null) {
      return null;
    }
    return directory == '~' ? home : _joinPath(home, directory.substring(2));
  }
  return directory;
}

String _joinPath(String base, String child) {
  final separator = Platform.pathSeparator;
  if (base.endsWith('/') || base.endsWith('\\')) {
    return '$base$child';
  }
  return '$base$separator$child';
}
