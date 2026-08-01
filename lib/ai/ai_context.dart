import 'package:flutter/foundation.dart';

import '../terminal/terminal_controller.dart';
import '../terminal/terminal_selection.dart';

enum AiContextKind { commandBlock, terminalSelection, recentOutput }

@immutable
class AiContextAttachment {
  const AiContextAttachment({
    required this.kind,
    required this.label,
    required this.content,
    this.redacted = false,
  });

  final AiContextKind kind;
  final String label;
  final String content;
  final bool redacted;
}

@immutable
class AiTerminalContext {
  const AiTerminalContext({
    required this.terminalLabel,
    required this.attachments,
  });

  final String terminalLabel;
  final List<AiContextAttachment> attachments;

  bool get isEmpty => attachments.isEmpty;

  AiTerminalContext whereKinds(Set<AiContextKind> kinds) {
    return AiTerminalContext(
      terminalLabel: terminalLabel,
      attachments: [
        for (final attachment in attachments)
          if (kinds.contains(attachment.kind)) attachment,
      ],
    );
  }

  String toPromptText() {
    if (attachments.isEmpty) {
      return '';
    }
    final buffer = StringBuffer()
      ..writeln('<terminal_context>')
      ..writeln('terminal: ${_escapeContextText(terminalLabel)}');
    for (final attachment in attachments) {
      buffer
        ..writeln('<${attachment.kind.name}>')
        ..writeln(_escapeContextText(attachment.content))
        ..writeln('</${attachment.kind.name}>');
    }
    buffer.write('</terminal_context>');
    return buffer.toString();
  }

  static AiTerminalContext capture({
    required TerminalController controller,
    required bool includeSelection,
    required bool includeRecentOutput,
    int maximumCharacters = 12000,
  }) {
    final attachments = <AiContextAttachment>[];
    final selectedText = controller.selectedText.trim();
    if (includeSelection && selectedText.isNotEmpty) {
      final block = controller.selectedCommandBlock;
      attachments.add(
        _attachment(
          kind: block == null
              ? AiContextKind.terminalSelection
              : AiContextKind.commandBlock,
          label: block == null ? 'Selection' : 'Command block',
          content: block == null
              ? selectedText
              : _commandBlockContent(block, selectedText),
          maximumCharacters: maximumCharacters,
        ),
      );
    }

    if (includeRecentOutput) {
      final visibleSelection = terminalVisibleTextSelection(
        controller.snapshot,
      );
      final visibleOutput = visibleSelection == null
          ? ''
          : terminalSelectedText(controller.snapshot, visibleSelection).trim();
      if (visibleOutput.isNotEmpty && visibleOutput != selectedText) {
        attachments.add(
          _attachment(
            kind: AiContextKind.recentOutput,
            label: 'Recent output',
            content: visibleOutput,
            maximumCharacters: maximumCharacters,
          ),
        );
      }
    }

    return AiTerminalContext(
      terminalLabel: _terminalLabel(controller),
      attachments: List.unmodifiable(attachments),
    );
  }

  static AiContextAttachment _attachment({
    required AiContextKind kind,
    required String label,
    required String content,
    required int maximumCharacters,
  }) {
    final plainText = AiContextSanitizer.plainTerminalText(content);
    final truncated = _keepTail(plainText, maximumCharacters);
    final sanitized = AiContextSanitizer.redact(truncated);
    return AiContextAttachment(
      kind: kind,
      label: label,
      content: sanitized.text,
      redacted: sanitized.redacted,
    );
  }

  static String _commandBlockContent(
    TerminalCommandBlock block,
    String output,
  ) {
    final buffer = StringBuffer();
    if (block.id != null) {
      buffer.writeln('id: ${block.id}');
    }
    if (block.command case final command?) {
      buffer.writeln('command: $command');
    }
    if (block.workingDirectory case final workingDirectory?) {
      buffer.writeln('working_directory: $workingDirectory');
    }
    buffer.writeln('state: ${block.completed ? 'completed' : 'active'}');
    if (block.exitCode case final exitCode?) {
      buffer.writeln('exit_code: $exitCode');
    }
    buffer
      ..writeln('output:')
      ..write(output);
    return buffer.toString();
  }

  static String _terminalLabel(TerminalController controller) {
    final profile = controller.sshProfile;
    if (profile != null) {
      final label = profile.label?.trim();
      return label != null && label.isNotEmpty ? label : profile.host;
    }
    final title = controller.snapshot.title.trim();
    if (title.isNotEmpty) {
      return title;
    }
    final shell = controller.shellPath?.trim();
    return shell != null && shell.isNotEmpty ? shell : 'Local terminal';
  }
}

@immutable
class AiSanitizedText {
  const AiSanitizedText(this.text, {required this.redacted});

  final String text;
  final bool redacted;
}

class AiContextSanitizer {
  const AiContextSanitizer._();

  static String plainTerminalText(String input) {
    final output = <int>[];
    var index = 0;
    while (index < input.length) {
      final codeUnit = input.codeUnitAt(index);

      if (codeUnit == 0x1b) {
        index = _skipEscapeSequence(input, index + 1);
        continue;
      }
      if (codeUnit == 0x9b) {
        index = _skipCsi(input, index + 1);
        continue;
      }
      if (_isC1ControlString(codeUnit)) {
        index = _skipControlString(input, index + 1);
        continue;
      }
      if (codeUnit >= 0x80 && codeUnit <= 0x9f) {
        index += 1;
        continue;
      }
      if (codeUnit == 0x08) {
        _removeLastScalar(output);
        index += 1;
        continue;
      }
      if (codeUnit == 0x0d) {
        index += 1;
        continue;
      }
      if (codeUnit == 0x0a || codeUnit == 0x09) {
        output.add(codeUnit);
        index += 1;
        continue;
      }
      if (codeUnit < 0x20 || codeUnit == 0x7f) {
        index += 1;
        continue;
      }

      output.add(codeUnit);
      index += 1;
    }
    return String.fromCharCodes(output);
  }

  static final List<({RegExp pattern, String Function(Match) replacement})>
  _rules = [
    (
      pattern: RegExp(
        r'-----BEGIN [^-]*PRIVATE KEY-----[\s\S]*?-----END [^-]*PRIVATE KEY-----',
        caseSensitive: false,
      ),
      replacement: (_) => '[REDACTED PRIVATE KEY]',
    ),
    (
      pattern: RegExp(
        r'\b(authorization\s*:\s*(?:bearer|basic)\s+)[^\s]+',
        caseSensitive: false,
      ),
      replacement: (match) => '${match.group(1)}[REDACTED]',
    ),
    (
      pattern: RegExp(
        r'''\b([A-Za-z0-9_-]*(?:api[_-]?key|access[_-]?token|auth[_-]?token|password|passwd|secret|token))\s*([=:])\s*("[^"]*"|'[^']*'|[^\s]+)''',
        caseSensitive: false,
      ),
      replacement: (match) => '${match.group(1)}${match.group(2)}[REDACTED]',
    ),
    (
      pattern: RegExp(r'(https?://[^:/\s]+:)([^@\s]+)(@)'),
      replacement: (match) => '${match.group(1)}[REDACTED]${match.group(3)}',
    ),
    (
      pattern: RegExp(r'\bsk-[A-Za-z0-9_-]{16,}\b'),
      replacement: (_) => '[REDACTED API KEY]',
    ),
    (
      pattern: RegExp(r'\bgh[pousr]_[A-Za-z0-9]{20,}\b'),
      replacement: (_) => '[REDACTED TOKEN]',
    ),
    (
      pattern: RegExp(r'\bAKIA[A-Z0-9]{16}\b'),
      replacement: (_) => '[REDACTED ACCESS KEY]',
    ),
    (
      pattern: RegExp(r'\beyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\b'),
      replacement: (_) => '[REDACTED TOKEN]',
    ),
  ];

  static AiSanitizedText redact(String input) {
    var output = input;
    for (final rule in _rules) {
      output = output.replaceAllMapped(rule.pattern, rule.replacement);
    }
    return AiSanitizedText(output, redacted: output != input);
  }
}

int _skipEscapeSequence(String input, int index) {
  if (index >= input.length) {
    return input.length;
  }
  final codeUnit = input.codeUnitAt(index);
  if (codeUnit == 0x5b) {
    return _skipCsi(input, index + 1);
  }
  if (codeUnit == 0x5d ||
      codeUnit == 0x50 ||
      codeUnit == 0x58 ||
      codeUnit == 0x5e ||
      codeUnit == 0x5f) {
    return _skipControlString(input, index + 1);
  }

  var cursor = index;
  while (cursor < input.length) {
    final current = input.codeUnitAt(cursor);
    if (current < 0x20 || current > 0x2f) {
      break;
    }
    cursor += 1;
  }
  return cursor < input.length ? cursor + 1 : input.length;
}

int _skipCsi(String input, int index) {
  var cursor = index;
  while (cursor < input.length) {
    final codeUnit = input.codeUnitAt(cursor);
    cursor += 1;
    if (codeUnit >= 0x40 && codeUnit <= 0x7e) {
      break;
    }
  }
  return cursor;
}

int _skipControlString(String input, int index) {
  var cursor = index;
  while (cursor < input.length) {
    final codeUnit = input.codeUnitAt(cursor);
    if (codeUnit == 0x07 || codeUnit == 0x9c) {
      return cursor + 1;
    }
    if (codeUnit == 0x1b &&
        cursor + 1 < input.length &&
        input.codeUnitAt(cursor + 1) == 0x5c) {
      return cursor + 2;
    }
    cursor += 1;
  }
  return input.length;
}

bool _isC1ControlString(int codeUnit) {
  return codeUnit == 0x90 ||
      codeUnit == 0x98 ||
      codeUnit == 0x9d ||
      codeUnit == 0x9e ||
      codeUnit == 0x9f;
}

void _removeLastScalar(List<int> output) {
  if (output.isEmpty) {
    return;
  }
  final last = output.removeLast();
  if (_isLowSurrogate(last) &&
      output.isNotEmpty &&
      _isHighSurrogate(output.last)) {
    output.removeLast();
  }
}

String _keepTail(String value, int maximumCharacters) {
  if (maximumCharacters <= 0) {
    return '';
  }
  if (value.length <= maximumCharacters) {
    return value;
  }
  var start = value.length - maximumCharacters;
  if (start < value.length && _isLowSurrogate(value.codeUnitAt(start))) {
    start += 1;
  }
  return '[Earlier terminal output omitted]\n${value.substring(start)}';
}

bool _isLowSurrogate(int codeUnit) => codeUnit >= 0xdc00 && codeUnit <= 0xdfff;

bool _isHighSurrogate(int codeUnit) => codeUnit >= 0xd800 && codeUnit <= 0xdbff;

String _escapeContextText(String value) {
  return value
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;');
}
