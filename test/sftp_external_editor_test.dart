import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nauterm/terminal/external_editor_catalog.dart';
import 'package:nauterm/terminal/terminal_config.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.korvect.nauterm/external_editors');

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('resolves a saved editor command outside the inherited PATH', () {
    final resolved = resolveSftpExternalEditorExecutable(
      'code',
      environment: const {'PATH': '/usr/bin:/bin', 'HOME': '/Users/tester'},
      additionalSearchDirectories: const ['/usr/local/bin'],
      fileExists: (path) => path == '/usr/local/bin/code',
    );

    expect(resolved, '/usr/local/bin/code');
  });

  test('keeps an explicit editor executable path unchanged', () {
    final resolved = resolveSftpExternalEditorExecutable(
      '/Applications/Editor.app/Contents/MacOS/editor',
      environment: const {'PATH': '/usr/bin'},
      fileExists: (_) => false,
    );

    expect(resolved, '/Applications/Editor.app/Contents/MacOS/editor');
  });

  test('keeps an unresolved editor command for the process error', () {
    final resolved = resolveSftpExternalEditorExecutable(
      'missing-editor',
      environment: const {'PATH': '/usr/bin'},
      additionalSearchDirectories: const [],
      fileExists: (_) => false,
    );

    expect(resolved, 'missing-editor');
  });

  test('decodes application icons returned by the native catalog', () {
    final iconBytes = Uint8List.fromList([1, 2, 3, 4]);
    final applications = decodeSystemFileApplications([
      {
        'name': 'Editor',
        'bundleIdentifier': 'com.example.editor',
        'icon': iconBytes,
        'isDefault': true,
      },
    ]);

    expect(applications, hasLength(1));
    expect(applications.single.iconBytes, same(iconBytes));
    expect(applications.single.isDefault, isTrue);
    expect(applications.single.command.executable, '/usr/bin/open');
    expect(applications.single.command.arguments, ['-b', 'com.example.editor']);
  });

  test('does not query application handlers for extensionless files', () async {
    expect(await loadSystemApplicationsForFileName('README'), isEmpty);
  });

  test('opens macOS files through the native system association', () async {
    if (!Platform.isMacOS) return;
    MethodCall? receivedCall;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          receivedCall = call;
          return null;
        });

    await openFileWithSystemApplication('/tmp/readme.txt');

    expect(receivedCall?.method, 'openFile');
    expect(receivedCall?.arguments, {'path': '/tmp/readme.txt'});
  });

  test('extracts an application bundle identifier from an open command', () {
    expect(
      systemApplicationBundleIdentifier(
        const SftpExternalEditorCommand(
          label: 'Editor',
          executable: '/usr/bin/open',
          arguments: ['-b', 'com.example.editor'],
        ),
      ),
      'com.example.editor',
    );
    expect(
      systemApplicationBundleIdentifier(
        const SftpExternalEditorCommand(
          label: 'CLI Editor',
          executable: 'code',
        ),
      ),
      isNull,
    );
  });

  test('blocks executable files from the system default application', () {
    expect(
      canOpenFileWithSystemDefaultApplication(
        'deploy.sh',
        permissions: '-rw-r--r--',
      ),
      isFalse,
    );
    expect(
      canOpenFileWithSystemDefaultApplication(
        'tool',
        permissions: '-rwxr-xr-x',
      ),
      isFalse,
    );
    expect(
      canOpenFileWithSystemDefaultApplication(
        'setup.exe',
        permissions: '-rw-r--r--',
      ),
      isFalse,
    );
    expect(
      canOpenFileWithSystemDefaultApplication(
        'notes.txt',
        permissions: '-rw-r--r--',
      ),
      isTrue,
    );
  });

  test('normalizes configured text file extensions', () {
    expect(
      parseSftpTextFileExtensions(' .MD, *.json; yaml  md invalid/path '),
      ['md', 'json', 'yaml'],
    );
  });

  test('matches external editor extensions and extensionless files', () {
    final previousExtensions = sftpTextFileExtensions;
    addTearDown(() => sftpTextFileExtensions = previousExtensions);
    sftpTextFileExtensions = const ['txt', 'md'];

    expect(sftpExternalEditorSupportsFileName('notes.txt'), isTrue);
    expect(sftpExternalEditorSupportsFileName('README'), isTrue);
    expect(sftpExternalEditorSupportsFileName('archive.zip'), isFalse);
  });
}
