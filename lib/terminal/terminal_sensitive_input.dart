import 'dart:math' as math;

import 'terminal_models.dart';

final RegExp _sensitivePromptMethodPattern = RegExp(
  r"(?:password(?:\s+for\s+[^:]+)?|passphrase(?:\s+for\s+[^:]+)?|pin|otp|one[- ]?time(?:\s+password|\s+code)?|verification\s+code|security\s+code|auth(?:entication)?\s+code|token)\s*:?\s*$",
  caseSensitive: false,
);

final RegExp _sudoPromptPattern = RegExp(
  r"\[sudo\]\s+(.+)$",
  caseSensitive: false,
);

final RegExp _sudoRsAuthenticationPromptPattern = RegExp(
  r"\[sudo:\s*authenticate\]\s+(.+)$",
  caseSensitive: false,
);

bool terminalInputIsSensitive(TerminalSnapshot snapshot) {
  if (!snapshot.inputEchoEnabled) {
    return true;
  }
  if (snapshot.rows <= 0 || snapshot.columns <= 0) {
    return false;
  }

  final row = math.max(0, math.min(snapshot.rows - 1, snapshot.cursor.row));
  final currentLine = _snapshotLineText(snapshot, row);
  if (_lineLooksSensitivePrompt(currentLine)) {
    return true;
  }
  return currentLine.trim().isEmpty &&
      row > 0 &&
      _lineLooksSensitivePrompt(_snapshotLineText(snapshot, row - 1));
}

bool _lineLooksSensitivePrompt(String line) {
  final text = line.trimRight();
  if (text.isEmpty) {
    return false;
  }
  final sudoRsPrompt = _sudoRsAuthenticationPromptPattern.firstMatch(text);
  if (sudoRsPrompt != null) {
    return _isSensitivePromptMethod(sudoRsPrompt.group(1));
  }
  final sudoPrompt = _sudoPromptPattern.firstMatch(text);
  if (sudoPrompt != null) {
    return _isSensitivePromptMethod(sudoPrompt.group(1));
  }
  return _isSensitivePromptMethod(text);
}

bool _isSensitivePromptMethod(String? text) {
  final method = text?.trim();
  return method != null &&
      method.isNotEmpty &&
      _sensitivePromptMethodPattern.hasMatch(method);
}

String _snapshotLineText(TerminalSnapshot snapshot, int row) {
  final buffer = StringBuffer();
  for (var column = 0; column < snapshot.columns; column++) {
    final cell = snapshot.cellAt(row, column);
    if (!cell.wideCharSpacer && !cell.leadingWideCharSpacer) {
      buffer.write(cell.text);
    }
  }
  return buffer.toString();
}
