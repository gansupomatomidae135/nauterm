import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nauterm/ai/ai_attachment.dart';

void main() {
  test('text attachments are decoded and sanitized', () async {
    final attachment = await AiAttachment.fromFile(
      XFile.fromData(
        Uint8List.fromList(
          'hello\nAPI_KEY=sk-1234567890abcdefghijklmnop'.codeUnits,
        ),
        name: 'debug.log',
        mimeType: 'text/plain',
      ),
    );

    expect(attachment.kind, AiAttachmentKind.text);
    expect(attachment.text, contains('hello'));
    expect(attachment.text, contains('API_KEY=[REDACTED]'));
    expect(attachment.redacted, isTrue);
  });

  test('supported images retain bytes for provider encoding', () async {
    final bytes = Uint8List.fromList(<int>[
      0x89,
      0x50,
      0x4e,
      0x47,
      0x0d,
      0x0a,
      0x1a,
      0x0a,
    ]);
    final attachment = await AiAttachment.fromFile(
      XFile.fromData(bytes, name: 'screen.png', mimeType: 'image/png'),
    );

    expect(attachment.kind, AiAttachmentKind.image);
    expect(attachment.mimeType, 'image/png');
    expect(attachment.bytes, bytes);
    expect(attachment.base64Data, isNotEmpty);
  });

  test('unsupported binary files are rejected', () async {
    final file = XFile.fromData(
      Uint8List.fromList([0, 1, 2, 3]),
      name: 'archive.bin',
      mimeType: 'application/octet-stream',
    );

    await expectLater(
      AiAttachment.fromFile(file),
      throwsA(isA<AiAttachmentException>()),
    );
  });
}
