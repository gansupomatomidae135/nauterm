import 'package:flutter_test/flutter_test.dart';
import 'package:nauterm/workspace/workspace_composer_completion.dart';

void main() {
  const entries = [
    WorkspacePathCompletionEntry(name: 'Applications', isDirectory: true),
    WorkspacePathCompletionEntry(
      name: 'Application Support',
      isDirectory: true,
    ),
    WorkspacePathCompletionEntry(
      name: 'Applications (Parallels)',
      isDirectory: true,
    ),
    WorkspacePathCompletionEntry(name: 'app.log', isDirectory: false),
    WorkspacePathCompletionEntry(name: 'alpha.txt', isDirectory: false),
  ];

  test('directory commands only suggest directories', () {
    final query = WorkspaceComposerCompletion.shellPathQuery(
      'cd App',
      workingDirectory: '/Users/korvect',
      expandHome: true,
      home: '/Users/korvect',
    );

    expect(query, isNotNull);
    expect(WorkspaceComposerCompletion.pathCandidates(query!, entries), [
      'cd Application\\ Support/',
      'cd Applications/',
      r'cd Applications\ \(Parallels\)/',
    ]);
  });

  test('non-directory commands suggest directories and files', () {
    final query = WorkspaceComposerCompletion.shellPathQuery(
      'cat app',
      workingDirectory: '/Users/korvect',
      expandHome: true,
      home: '/Users/korvect',
    );

    expect(query, isNotNull);
    expect(WorkspaceComposerCompletion.pathCandidates(query!, entries), [
      'cat app.log',
      'cat Application\\ Support/',
      'cat Applications/',
      r'cat Applications\ \(Parallels\)/',
    ]);
  });

  test('path candidates escape shell glob metacharacters', () {
    final query = WorkspaceComposerCompletion.shellPathQuery(
      'ls Applications',
      workingDirectory: '/Users/korvect',
      expandHome: true,
      home: '/Users/korvect',
    );

    expect(query, isNotNull);
    expect(
      WorkspaceComposerCompletion.pathCandidates(query!, const [
        WorkspacePathCompletionEntry(
          name: 'Applications (Parallels)',
          isDirectory: true,
        ),
      ]),
      [r'ls Applications\ \(Parallels\)/'],
    );
  });

  test('high default suggestion limit keeps files visible', () {
    final query = WorkspaceComposerCompletion.shellPathQuery(
      'cat ',
      workingDirectory: '/Users/korvect',
      expandHome: true,
      home: '/Users/korvect',
    );

    final crowdedEntries = [
      for (var index = 0; index < 10; index++)
        WorkspacePathCompletionEntry(name: 'dir$index', isDirectory: true),
      for (var index = 0; index < 3; index++)
        WorkspacePathCompletionEntry(
          name: 'file$index.txt',
          isDirectory: false,
        ),
    ];

    expect(query, isNotNull);
    final candidates = WorkspaceComposerCompletion.pathCandidates(
      query!,
      crowdedEntries,
    );
    expect(
      candidates.where((candidate) => candidate.endsWith('.txt')),
      isNotEmpty,
    );
  });

  test('path candidates default to a high suggestion limit', () {
    final query = WorkspaceComposerCompletion.shellPathQuery(
      'cat item',
      workingDirectory: '/Users/korvect',
      expandHome: true,
      home: '/Users/korvect',
    );

    final manyEntries = [
      for (var index = 0; index < 20; index++)
        WorkspacePathCompletionEntry(
          name: 'item$index.txt',
          isDirectory: false,
        ),
    ];

    expect(query, isNotNull);
    expect(
      WorkspaceComposerCompletion.pathCandidates(query!, manyEntries),
      hasLength(20),
    );
  });

  test('path candidate limit is configurable', () {
    final query = WorkspaceComposerCompletion.shellPathQuery(
      'cat item',
      workingDirectory: '/Users/korvect',
      expandHome: true,
      home: '/Users/korvect',
    );

    final manyEntries = [
      for (var index = 0; index < 20; index++)
        WorkspacePathCompletionEntry(
          name: 'item$index.txt',
          isDirectory: false,
        ),
    ];

    expect(query, isNotNull);
    expect(
      WorkspaceComposerCompletion.pathCandidates(query!, manyEntries, limit: 5),
      hasLength(5),
    );
  });

  test('quoted directory candidates keep the quote open', () {
    final query = WorkspaceComposerCompletion.shellPathQuery(
      'cat "Applic',
      workingDirectory: '/Users/korvect',
      expandHome: true,
      home: '/Users/korvect',
    );

    expect(query, isNotNull);
    expect(WorkspaceComposerCompletion.pathCandidates(query!, entries), [
      'cat "Application Support/',
      'cat "Applications/',
      'cat "Applications (Parallels)/',
    ]);
  });

  test('quoted file candidates close the quote', () {
    final query = WorkspaceComposerCompletion.shellPathQuery(
      'cat "alp',
      workingDirectory: '/Users/korvect',
      expandHome: true,
      home: '/Users/korvect',
    );

    expect(query, isNotNull);
    expect(WorkspaceComposerCompletion.pathCandidates(query!, entries), [
      'cat "alpha.txt"',
    ]);
  });

  test('inline file options preserve option prefix and quote', () {
    final query = WorkspaceComposerCompletion.shellPathQuery(
      'tool --file="Applic',
      workingDirectory: '/Users/korvect',
      expandHome: true,
      home: '/Users/korvect',
    );

    expect(query, isNotNull);
    expect(WorkspaceComposerCompletion.pathCandidates(query!, entries), [
      'tool --file="Application Support/',
      'tool --file="Applications/',
      'tool --file="Applications (Parallels)/',
    ]);
  });
}
