import 'dart:io';

List<String> discoverSystemShells({String? current}) {
  final shells = <String>{};
  if (Platform.isWindows) {
    shells.addAll(_windowsShells());
  } else {
    final environmentShell = _nonEmpty(Platform.environment['SHELL']);
    if (environmentShell != null) shells.add(environmentShell);

    final shellsFile = File('/etc/shells');
    if (shellsFile.existsSync()) {
      for (final rawLine in shellsFile.readAsLinesSync()) {
        final line = rawLine.trim();
        if (line.startsWith('/') && File(line).existsSync()) shells.add(line);
      }
    }
  }
  final configured = _nonEmpty(current);
  if (configured != null) shells.add(configured);

  final values = shells.toList(growable: false)
    ..sort((a, b) {
      final defaultPath = systemDefaultShellPath();
      final aDefault = a == defaultPath;
      final bDefault = b == defaultPath;
      if (aDefault != bDefault) return aDefault ? -1 : 1;
      final nameOrder = shellDisplayName(a).compareTo(shellDisplayName(b));
      return nameOrder != 0 ? nameOrder : a.compareTo(b);
    });
  return values;
}

String? systemDefaultShellPath() {
  return _nonEmpty(
    Platform.isWindows
        ? Platform.environment['COMSPEC']
        : Platform.environment['SHELL'],
  );
}

String shellDisplayName(String path) {
  final normalized = path.replaceAll('\\', '/');
  final name = normalized.split('/').last;
  return switch (name.toLowerCase()) {
    'pwsh' || 'pwsh.exe' => 'PowerShell 7',
    'powershell' || 'powershell.exe' => 'Windows PowerShell',
    'cmd' || 'cmd.exe' => 'Command Prompt',
    _ => name,
  };
}

List<String> _windowsShells() {
  final shells = <String>{};
  final environment = Platform.environment;
  final systemRoot = _nonEmpty(environment['SystemRoot']);
  final programFiles = _nonEmpty(environment['ProgramFiles']);
  final candidates = <String>[
    if (programFiles != null) '$programFiles\\PowerShell\\7\\pwsh.exe',
    ..._executablesFromPath('pwsh.exe'),
    if (systemRoot != null)
      '$systemRoot\\System32\\WindowsPowerShell\\v1.0\\powershell.exe',
    ..._executablesFromPath('powershell.exe'),
    ?_nonEmpty(environment['COMSPEC']),
    if (systemRoot != null) '$systemRoot\\System32\\cmd.exe',
    ..._executablesFromPath('cmd.exe'),
  ];
  for (final candidate in candidates) {
    if (File(candidate).existsSync()) shells.add(candidate);
  }
  return shells.toList(growable: false);
}

List<String> _executablesFromPath(String executable) {
  final path = _nonEmpty(Platform.environment['PATH']);
  if (path == null) return const [];
  return [
    for (final directory in path.split(';'))
      if (directory.trim().isNotEmpty) '${directory.trim()}\\$executable',
  ];
}

String? _nonEmpty(String? value) {
  final trimmed = value?.trim();
  return trimmed == null || trimmed.isEmpty ? null : trimmed;
}
