part of 'nauterm_workspace.dart';

String? _emptyToNull(String? value) {
  final trimmed = value?.trim();
  if (trimmed == null) {
    return null;
  }
  return trimmed.isEmpty ? null : trimmed;
}

String? _firstNonEmpty(Iterable<String?> values) {
  for (final value in values) {
    final trimmed = value?.trim();
    if (trimmed != null && trimmed.isNotEmpty) {
      return trimmed;
    }
  }
  return null;
}

({String text, int added}) _mergeKnownHostsText(
  String currentText,
  String importedText,
) {
  final mergedLines = <String>[];
  final seen = <String>{};

  for (final rawLine in currentText.split('\n')) {
    final line = rawLine.replaceFirst(RegExp(r'\r$'), '');
    if (line.isEmpty && rawLine == currentText.split('\n').last) {
      continue;
    }
    mergedLines.add(line);

    final key = _knownHostLineKey(line);
    if (key != null) {
      seen.add(key);
    }
  }

  var added = 0;
  for (final rawLine in importedText.split('\n')) {
    final line = rawLine.replaceFirst(RegExp(r'\r$'), '');
    final key = _knownHostLineKey(line);
    if (key == null || !seen.add(key)) {
      continue;
    }
    mergedLines.add(line);
    added++;
  }

  while (mergedLines.isNotEmpty && mergedLines.last.trim().isEmpty) {
    mergedLines.removeLast();
  }

  return (
    text: mergedLines.isEmpty ? '' : '${mergedLines.join('\n')}\n',
    added: added,
  );
}

String? _knownHostLineKey(String line) {
  final trimmed = line.trim();
  if (trimmed.isEmpty || trimmed.startsWith('#')) {
    return null;
  }

  final fields = trimmed.split(RegExp(r'\s+'));
  final hostFieldIndex = fields.first.startsWith('@') ? 1 : 0;
  if (fields.length <= hostFieldIndex + 1) {
    return null;
  }

  return fields.join(' ');
}

int? _intFromText(String value) => int.tryParse(value.trim());

double _measureWorkspaceSelectorText(
  BuildContext context,
  String text,
  TextStyle style,
) {
  final painter = TextPainter(
    text: TextSpan(text: text, style: style),
    maxLines: 1,
    textDirection: Directionality.of(context),
    textScaler: MediaQuery.textScalerOf(context),
  )..layout();
  return painter.width;
}
