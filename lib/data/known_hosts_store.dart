import 'dart:io';

class KnownHostsStore {
  const KnownHostsStore(this.file);

  final File file;

  Future<String> readText() async {
    if (!await file.exists()) {
      return '';
    }
    return file.readAsString();
  }

  Future<void> writeText(String text) async {
    await file.parent.create(recursive: true);
    await file.writeAsString(text);
  }
}
