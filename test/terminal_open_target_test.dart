import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nauterm/terminal/terminal_models.dart';
import 'package:nauterm/terminal/terminal_open_target.dart';
import 'package:nauterm/terminal/terminal_selection.dart';
import 'package:nauterm/terminal/terminal_theme.dart';

void main() {
  test('local terminal resolves a relative path from the nearest prompt', () {
    final root = Directory.systemTemp.createTempSync('nauterm-open-target-');
    addTearDown(() => root.deleteSync(recursive: true));
    final file = File('${root.path}/report.txt')..writeAsStringSync('report');
    final snapshot = _snapshotFromLines([
      'user@host:${root.path} \$ ls',
      'report.txt',
    ]);

    final target = terminalOpenTargetAt(
      snapshot,
      const TerminalCellPosition(row: 1, column: 3),
      allowLocalPaths: true,
    );

    expect(target?.localPath, isTrue);
    expect(target?.uri.toFilePath(), file.path);
  });

  test('local terminal recognizes an existing plain directory name', () {
    final root = Directory.systemTemp.createTempSync('nauterm-open-target-');
    addTearDown(() => root.deleteSync(recursive: true));
    final directory = Directory('${root.path}/Projects')..createSync();
    final snapshot = _snapshotFromLines([
      'user@host:${root.path} \$ ls',
      'Projects',
    ]);

    final target = terminalOpenTargetAt(
      snapshot,
      const TerminalCellPosition(row: 1, column: 3),
      allowLocalPaths: true,
    );

    expect(target?.localPath, isTrue);
    expect(target?.uri.toFilePath(), directory.path);
  });

  test('long output resolves paths from a prompt outside the viewport', () {
    final root = Directory.systemTemp.createTempSync('nauterm-open-target-');
    addTearDown(() => root.deleteSync(recursive: true));
    final directory = Directory('${root.path}/Projects')..createSync();
    final snapshot = _snapshotFromLines([
      'drwxr-xr-x  4 user staff 128 Jul 18 12:00 Projects',
    ]);

    final target = terminalOpenTargetAt(
      snapshot,
      const TerminalCellPosition(row: 0, column: 44),
      allowLocalPaths: true,
      commandPromptText: 'user@host:${root.path} \$ ll',
    );

    expect(target?.uri.toFilePath(), directory.path);
  });

  test('shell integration cwd takes priority over visible prompt parsing', () {
    final root = Directory.systemTemp.createTempSync('nauterm-open-target-');
    addTearDown(() => root.deleteSync(recursive: true));
    final file = File('${root.path}/report.txt')..writeAsStringSync('report');
    final snapshot = _snapshotFromLines(['report.txt']);

    final target = terminalOpenTargetAt(
      snapshot,
      const TerminalCellPosition(row: 0, column: 3),
      allowLocalPaths: true,
      commandPromptText: r'user@host:/wrong $ ls',
      commandWorkingDirectory: root.path,
    );

    expect(target?.uri.toFilePath(), file.path);
  });

  test('local terminal opens the working directory shown in the prompt', () {
    final root = Directory.systemTemp.createTempSync('nauterm-open-target-');
    addTearDown(() => root.deleteSync(recursive: true));
    final line = 'user@host:${root.path} \$ ls';
    final snapshot = _snapshotFromLines([line]);

    final target = terminalOpenTargetAt(
      snapshot,
      TerminalCellPosition(row: 0, column: line.indexOf(root.path) + 2),
      allowLocalPaths: true,
    );

    expect(target?.uri.toFilePath(), root.path);
  });

  test('ll recognizes a complete file name containing spaces', () {
    final root = Directory.systemTemp.createTempSync('nauterm-open-target-');
    addTearDown(() => root.deleteSync(recursive: true));
    final file = File('${root.path}/Quarterly Report (Final).txt')
      ..writeAsStringSync('report');
    const name = 'Quarterly Report (Final).txt';
    const line =
        '-rw-r--r--@ 1 user staff 6 Jul 18 12:00 Quarterly Report (Final).txt';
    final snapshot = _snapshotFromLines([line]);

    final target = terminalOpenTargetAt(
      snapshot,
      TerminalCellPosition(row: 0, column: line.indexOf('Report') + 2),
      allowLocalPaths: true,
      commandPromptText: 'user@host:${root.path} \$ ll',
    );

    expect(target?.value, name);
    expect(target?.uri.toFilePath(), file.path);
  });

  test('plain ls recognizes an existing directory containing spaces', () {
    final root = Directory.systemTemp.createTempSync('nauterm-open-target-');
    addTearDown(() => root.deleteSync(recursive: true));
    final directory = Directory('${root.path}/Applications (Parallels)')
      ..createSync();
    const line = 'Applications (Parallels)';
    final snapshot = _snapshotFromLines([line]);

    final target = terminalOpenTargetAt(
      snapshot,
      TerminalCellPosition(row: 0, column: line.indexOf('Parallels') + 2),
      allowLocalPaths: true,
      commandPromptText: 'user@host:${root.path} \$ ls',
    );

    expect(target?.uri.toFilePath(), directory.path);
  });

  test(
    'cat output recognizes a real local path without command whitelists',
    () {
      final root = Directory.systemTemp.createTempSync('nauterm-open-target-');
      addTearDown(() => root.deleteSync(recursive: true));
      final file = File('${root.path}/Referenced File.txt')
        ..writeAsStringSync('referenced');
      const line = 'See Referenced File.txt for details.';
      final snapshot = _snapshotFromLines([line]);

      final target = terminalOpenTargetAt(
        snapshot,
        TerminalCellPosition(row: 0, column: line.indexOf('File') + 2),
        allowLocalPaths: true,
        commandPromptText: 'user@host:${root.path} \$ cat README.md',
      );

      expect(target?.uri.toFilePath(), file.path);
    },
  );

  test('source identifiers containing dots are not local paths', () {
    final snapshot = _snapshotFromLines([
      r'user@host:/tmp $ cat index.html',
      "wrapper.addEventListener('mouseleave', reset);",
    ]);

    final target = terminalOpenTargetAt(
      snapshot,
      const TerminalCellPosition(row: 1, column: 12),
      allowLocalPaths: true,
    );

    expect(target, isNull);
  });

  test('prompt exposes only its working-directory span', () {
    final home = Platform.environment['HOME'];
    expect(home, isNotNull);
    final line = 'korvect@korvects-Mini.lan:$home \$ ';
    final snapshot = _snapshotFromLines([line]);
    final pathStart = line.indexOf(home!);
    final target = terminalOpenTargetAt(
      snapshot,
      TerminalCellPosition(row: 0, column: pathStart + 2),
      allowLocalPaths: true,
    );

    expect(target?.uri.toFilePath(), home);
    expect(target?.selection.start, pathStart);
    expect(target?.selection.end, pathStart + home.length);
    expect(
      terminalOpenTargetAt(
        snapshot,
        const TerminalCellPosition(row: 0, column: 3),
        allowLocalPaths: true,
      ),
      isNull,
    );
  });

  test('remote terminal ignores paths but recognizes web URLs', () {
    final snapshot = _snapshotFromLines([
      r'user@host:/tmp $ printf',
      'report.txt https://example.com/docs',
    ]);

    expect(
      terminalOpenTargetAt(
        snapshot,
        const TerminalCellPosition(row: 1, column: 3),
        allowLocalPaths: false,
      ),
      isNull,
    );
    final url = terminalOpenTargetAt(
      snapshot,
      const TerminalCellPosition(row: 1, column: 20),
      allowLocalPaths: false,
    );
    expect(url?.localPath, isFalse);
    expect(url?.uri, Uri.parse('https://example.com/docs'));
  });

  test('OSC 8 hyperlink takes priority over visible cell text', () {
    final cells = List<TerminalCell>.generate(
      4,
      (index) => const TerminalCell(
        text: 'link',
        foreground: terminalDefaultForeground,
        background: terminalDefaultBackground,
        flags: 0,
        hyperlink: 'https://example.com/target',
      ),
    );
    final snapshot = TerminalSnapshot(
      columns: 4,
      rows: 1,
      cells: cells,
      cursor: const TerminalCursor(
        column: 0,
        row: 0,
        visible: true,
        shape: TerminalCursorShape.block,
        color: terminalDefaultCursor,
        blinking: false,
      ),
      keyboardMode: const TerminalKeyboardMode(),
    );

    final target = terminalOpenTargetAt(
      snapshot,
      const TerminalCellPosition(row: 0, column: 2),
      allowLocalPaths: false,
    );
    expect(target?.uri, Uri.parse('https://example.com/target'));
  });
}

TerminalSnapshot _snapshotFromLines(List<String> lines) {
  final columns = lines.fold<int>(
    1,
    (width, line) => line.length > width ? line.length : width,
  );
  final cells = <TerminalCell>[];
  for (final line in lines) {
    for (var column = 0; column < columns; column++) {
      cells.add(
        TerminalCell(
          text: column < line.length ? line[column] : ' ',
          foreground: terminalDefaultForeground,
          background: terminalDefaultBackground,
          flags: 0,
        ),
      );
    }
  }
  return TerminalSnapshot(
    columns: columns,
    rows: lines.length,
    cells: cells,
    cursor: const TerminalCursor(
      column: 0,
      row: 0,
      visible: true,
      shape: TerminalCursorShape.block,
      color: terminalDefaultCursor,
      blinking: false,
    ),
    keyboardMode: const TerminalKeyboardMode(),
  );
}
