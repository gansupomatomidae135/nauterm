import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nauterm/data/known_hosts_store.dart';

void main() {
  test('known hosts store reads and writes plain text', () async {
    final directory = Directory.systemTemp.createTempSync(
      'nauterm_known_hosts_test_',
    );
    addTearDown(() => directory.deleteSync(recursive: true));

    final file = File('${directory.path}${Platform.pathSeparator}known_hosts');
    final store = KnownHostsStore(file);

    expect(await store.readText(), isEmpty);

    await store.writeText('example.com ssh-ed25519 AAAA\\n');

    expect(await store.readText(), 'example.com ssh-ed25519 AAAA\\n');
  });
}
