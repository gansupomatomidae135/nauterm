import 'dart:convert';
import 'dart:math' as math;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:mime/mime.dart';

import 'ai_context.dart';

enum AiAttachmentKind { image, text }

@immutable
class AiAttachment {
  const AiAttachment({
    required this.id,
    required this.name,
    required this.mimeType,
    required this.size,
    required this.kind,
    this.text,
    this.bytes,
    this.redacted = false,
  });

  static const int maximumCount = 5;
  static const int maximumImageBytes = 5 * 1024 * 1024;
  static const int maximumTextBytes = 512 * 1024;
  static const int maximumTextCharacters = 50000;

  final String id;
  final String name;
  final String mimeType;
  final int size;
  final AiAttachmentKind kind;
  final String? text;
  final Uint8List? bytes;
  final bool redacted;

  String? get base64Data {
    final data = bytes;
    return data == null ? null : base64Encode(data);
  }

  static Future<AiAttachment> fromFile(XFile file) async {
    final size = await file.length();
    final header = await file
        .openRead(0, math.min(size, 16))
        .fold<List<int>>(<int>[], (bytes, chunk) => bytes..addAll(chunk));
    final declaredMimeType = file.mimeType;
    final detectedMimeType = lookupMimeType(file.name, headerBytes: header);
    final mimeType =
        (declaredMimeType == null ||
                declaredMimeType == 'application/octet-stream'
            ? detectedMimeType ?? declaredMimeType
            : declaredMimeType) ??
        'application/octet-stream';
    final id = '${DateTime.now().microsecondsSinceEpoch}-${file.name.hashCode}';

    if (_supportedImageTypes.contains(mimeType)) {
      if (size > maximumImageBytes) {
        throw AiAttachmentException(
          '${file.name} is larger than the 5 MB image limit.',
        );
      }
      return AiAttachment(
        id: id,
        name: file.name,
        mimeType: mimeType,
        size: size,
        kind: AiAttachmentKind.image,
        bytes: Uint8List.fromList(await file.readAsBytes()),
      );
    }

    if (_isTextFile(file.name, mimeType)) {
      if (size > maximumTextBytes) {
        throw AiAttachmentException(
          '${file.name} is larger than the 512 KB text limit.',
        );
      }
      final decoded = utf8.decode(
        await file.readAsBytes(),
        allowMalformed: true,
      );
      final truncated = decoded.length > maximumTextCharacters
          ? '${decoded.substring(0, maximumTextCharacters)}\n'
                '[Remaining file content omitted]'
          : decoded;
      final sanitized = AiContextSanitizer.redact(truncated);
      return AiAttachment(
        id: id,
        name: file.name,
        mimeType: mimeType,
        size: size,
        kind: AiAttachmentKind.text,
        text: sanitized.text,
        redacted: sanitized.redacted,
      );
    }

    throw AiAttachmentException(
      '${file.name} is not a supported image or text file.',
    );
  }
}

class AiAttachmentException implements Exception {
  const AiAttachmentException(this.message);

  final String message;

  @override
  String toString() => message;
}

const Set<String> _supportedImageTypes = {
  'image/jpeg',
  'image/png',
  'image/gif',
  'image/webp',
};

const Set<String> _textExtensions = {
  'bash',
  'c',
  'cc',
  'conf',
  'cpp',
  'css',
  'csv',
  'dart',
  'env',
  'fish',
  'go',
  'h',
  'hpp',
  'html',
  'ini',
  'java',
  'js',
  'json',
  'kt',
  'log',
  'md',
  'py',
  'rb',
  'rs',
  'sh',
  'sql',
  'toml',
  'ts',
  'tsx',
  'txt',
  'xml',
  'yaml',
  'yml',
  'zsh',
};

bool _isTextFile(String name, String mimeType) {
  if (mimeType.startsWith('text/') ||
      mimeType == 'application/json' ||
      mimeType == 'application/xml' ||
      mimeType == 'application/x-yaml') {
    return true;
  }
  final dot = name.lastIndexOf('.');
  if (dot == -1 || dot == name.length - 1) {
    return false;
  }
  return _textExtensions.contains(name.substring(dot + 1).toLowerCase());
}
