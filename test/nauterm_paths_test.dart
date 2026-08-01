import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nauterm/data/nauterm_paths.dart';

void main() {
  test('uses a product name for user data directories', () {
    const environment = _TestEnvironment({
      'HOME': '/home/tester',
      'USERPROFILE': r'C:\Users\tester',
      'APPDATA': r'C:\Users\tester\AppData\Roaming',
      'XDG_CONFIG_HOME': '/home/tester/.config',
      'XDG_DATA_HOME': '/home/tester/.local/share',
    });

    final paths = NautermPaths.resolve(environment: environment);

    if (Platform.isMacOS) {
      expect(
        paths.dataDirectory.path,
        endsWith(
          [
            'Library',
            'Application Support',
            'Nauterm',
          ].join(Platform.pathSeparator),
        ),
      );
      expect(
        paths.additionalThemeDirectories.single.path,
        '/home/tester/.config/Nauterm/themes',
      );
    } else if (Platform.isWindows) {
      expect(
        paths.dataDirectory.path,
        endsWith('${Platform.pathSeparator}Nauterm'),
      );
    } else {
      expect(paths.configDirectory.path, '/home/tester/.config/nauterm');
      expect(paths.dataDirectory.path, '/home/tester/.local/share/nauterm');
    }

    expect(paths.databaseFile.path, endsWith('nauterm.sqlite'));
  });
}

class _TestEnvironment extends PlatformEnvironment {
  const _TestEnvironment(this.values);

  final Map<String, String> values;

  @override
  String? value(String key) => values[key];
}
