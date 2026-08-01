import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'ai_config.dart';
import 'ai_attachment.dart';

enum AiChatRole { system, user, assistant, tool }

sealed class AiStreamEvent {
  const AiStreamEvent();
}

class AiTextDelta extends AiStreamEvent {
  const AiTextDelta(this.text);

  final String text;
}

class AiToolCall extends AiStreamEvent {
  const AiToolCall({
    required this.id,
    required this.name,
    required this.arguments,
  });

  final String id;
  final String name;
  final Map<String, Object?> arguments;

  String? get terminalCommand {
    if (name != 'run_terminal_command') {
      return null;
    }
    return _nonEmptyString(arguments['command']);
  }

  String? get terminalCommandExplanation {
    if (name != 'run_terminal_command') {
      return null;
    }
    return _nonEmptyString(arguments['explanation']);
  }
}

class AiChatMessage {
  const AiChatMessage({
    this.persistenceId,
    required this.role,
    required this.content,
    this.context = '',
    this.sequence = 0,
    this.toolCalls = const [],
    this.toolResult,
    this.attachments = const [],
    this.createdAt,
    this.updatedAt,
  });

  final String? persistenceId;
  final AiChatRole role;
  final String content;
  final String context;
  final int sequence;
  final List<AiToolCall> toolCalls;
  final AiToolResult? toolResult;
  final List<AiAttachment> attachments;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  String get requestContent {
    final trimmedContext = context.trim();
    if (trimmedContext.isEmpty) {
      return content;
    }
    return '$content\n\n$trimmedContext';
  }

  AiChatMessage copyWith({
    String? content,
    List<AiToolCall>? toolCalls,
    AiToolResult? toolResult,
    List<AiAttachment>? attachments,
    DateTime? updatedAt,
  }) {
    return AiChatMessage(
      persistenceId: persistenceId,
      role: role,
      content: content ?? this.content,
      context: context,
      sequence: sequence,
      toolCalls: toolCalls ?? this.toolCalls,
      toolResult: toolResult ?? this.toolResult,
      attachments: attachments ?? this.attachments,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}

class AiToolResult {
  const AiToolResult({
    required this.toolCallId,
    required this.name,
    required this.content,
    this.isError = false,
  });

  final String toolCallId;
  final String name;
  final String content;
  final bool isError;
}

class AiProtocolException implements Exception {
  const AiProtocolException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => message;
}

typedef AiHttpClientFactory = HttpClient Function();

class AiProtocolClient {
  AiProtocolClient({AiHttpClientFactory? httpClientFactory})
    : _httpClientFactory = httpClientFactory ?? HttpClient.new;

  final AiHttpClientFactory _httpClientFactory;

  Stream<AiStreamEvent> streamCompletion({
    required AiAssistantConfig config,
    required List<AiChatMessage> messages,
    bool enableTerminalTool = false,
  }) {
    HttpClient? activeClient;
    return _cancellableStream(
      source: () {
        final client = _httpClientFactory();
        activeClient = client;
        client.connectionTimeout = const Duration(seconds: 20);
        return switch (config.protocol) {
          AiApiProtocol.openAi => _streamOpenAi(
            client,
            config,
            messages,
            enableTerminalTool: enableTerminalTool,
          ),
          AiApiProtocol.anthropic => _streamAnthropic(
            client,
            config,
            messages,
            enableTerminalTool: enableTerminalTool,
          ),
        };
      },
      abort: () => activeClient?.close(force: true),
    );
  }

  Stream<AiStreamEvent> _streamOpenAi(
    HttpClient client,
    AiAssistantConfig config,
    List<AiChatMessage> messages, {
    required bool enableTerminalTool,
  }) async* {
    final toolCalls = <int, _ToolCallAccumulator>{};
    try {
      final request = await client.postUrl(
        _versionedEndpoint(config.baseUrl, 'chat/completions'),
      );
      request.headers
        ..contentType = ContentType.json
        ..set(HttpHeaders.acceptHeader, 'text/event-stream')
        ..set(
          HttpHeaders.authorizationHeader,
          'Bearer ${config.apiKey.trim()}',
        );
      request.add(
        utf8.encode(
          jsonEncode(<String, Object?>{
            'model': config.model.trim(),
            'stream': true,
            'messages': [
              for (final message in messages) _openAiMessage(message),
            ],
            if (enableTerminalTool) 'tools': [_openAiTerminalCommandTool],
          }),
        ),
      );
      final response = await request.close();
      await _throwForError(response);
      await for (final data in _sseData(response)) {
        if (data.trim() == '[DONE]') {
          break;
        }
        final event = _jsonMap(data);
        final error = _nestedMap(event['error']);
        if (error != null) {
          throw AiProtocolException(
            _nonEmptyString(error['message']) ?? 'OpenAI request failed.',
          );
        }
        final choices = event['choices'];
        if (choices is! List || choices.isEmpty) {
          continue;
        }
        final choice = _nestedMap(choices.first);
        final delta = _nestedMap(choice?['delta']);
        final rawToolCalls = delta?['tool_calls'];
        if (rawToolCalls is List) {
          for (final rawToolCall in rawToolCalls) {
            final toolCall = _nestedMap(rawToolCall);
            if (toolCall == null) {
              continue;
            }
            final index = (toolCall['index'] as num?)?.toInt() ?? 0;
            final accumulator = toolCalls.putIfAbsent(
              index,
              _ToolCallAccumulator.new,
            );
            accumulator.id += toolCall['id'] as String? ?? '';
            final function = _nestedMap(toolCall['function']);
            accumulator.name += function?['name'] as String? ?? '';
            accumulator.arguments += function?['arguments'] as String? ?? '';
          }
        }
        final content = delta?['content'];
        if (content is String && content.isNotEmpty) {
          yield AiTextDelta(content);
        } else if (content is List) {
          for (final part in content) {
            final text = _nonEmptyString(_nestedMap(part)?['text']);
            if (text != null) {
              yield AiTextDelta(text);
            }
          }
        }
      }
      for (final toolCall
          in toolCalls.entries.toList()
            ..sort((left, right) => left.key.compareTo(right.key))) {
        final event = toolCall.value.toEvent();
        if (event != null) {
          yield event;
        }
      }
    } finally {
      client.close(force: true);
    }
  }

  Stream<AiStreamEvent> _streamAnthropic(
    HttpClient client,
    AiAssistantConfig config,
    List<AiChatMessage> messages, {
    required bool enableTerminalTool,
  }) async* {
    final toolCalls = <int, _ToolCallAccumulator>{};
    try {
      final request = await client.postUrl(
        _versionedEndpoint(config.baseUrl, 'messages'),
      );
      request.headers
        ..contentType = ContentType.json
        ..set(HttpHeaders.acceptHeader, 'text/event-stream')
        ..set('x-api-key', config.apiKey.trim())
        ..set('anthropic-version', '2023-06-01');
      final system = messages
          .where((message) => message.role == AiChatRole.system)
          .map((message) => message.content)
          .where((content) => content.trim().isNotEmpty)
          .join('\n\n');
      request.add(
        utf8.encode(
          jsonEncode(<String, Object?>{
            'model': config.model.trim(),
            'max_tokens': config.maxTokens,
            'stream': true,
            if (system.isNotEmpty) 'system': system,
            'messages': _anthropicMessages(messages),
            if (enableTerminalTool) 'tools': [_anthropicTerminalCommandTool],
          }),
        ),
      );
      final response = await request.close();
      await _throwForError(response);
      await for (final data in _sseData(response)) {
        final event = _jsonMap(data);
        final type = event['type'];
        if (type == 'message_stop') {
          for (final toolCall
              in toolCalls.entries.toList()
                ..sort((left, right) => left.key.compareTo(right.key))) {
            final event = toolCall.value.toEvent();
            if (event != null) {
              yield event;
            }
          }
          return;
        }
        if (type == 'error') {
          final error = _nestedMap(event['error']);
          throw AiProtocolException(
            _nonEmptyString(error?['message']) ?? 'Anthropic request failed.',
          );
        }
        if (type == 'content_block_start') {
          final contentBlock = _nestedMap(event['content_block']);
          if (contentBlock?['type'] == 'tool_use') {
            final index = (event['index'] as num?)?.toInt() ?? 0;
            final accumulator = toolCalls.putIfAbsent(
              index,
              _ToolCallAccumulator.new,
            );
            accumulator.id = contentBlock?['id'] as String? ?? '';
            accumulator.name = contentBlock?['name'] as String? ?? '';
            final input = contentBlock?['input'];
            if (input is Map && input.isNotEmpty) {
              accumulator.arguments = jsonEncode(input);
            }
          }
          continue;
        }
        if (type != 'content_block_delta') {
          continue;
        }
        final delta = _nestedMap(event['delta']);
        if (delta?['type'] == 'text_delta') {
          final text = _nonEmptyString(delta?['text']);
          if (text != null) {
            yield AiTextDelta(text);
          }
        } else if (delta?['type'] == 'input_json_delta') {
          final index = (event['index'] as num?)?.toInt() ?? 0;
          toolCalls.putIfAbsent(index, _ToolCallAccumulator.new).arguments +=
              delta?['partial_json'] as String? ?? '';
        }
      }
    } finally {
      client.close(force: true);
    }
  }
}

Stream<T> _cancellableStream<T>({
  required Stream<T> Function() source,
  required void Function() abort,
}) {
  StreamSubscription<T>? sourceSubscription;
  late final StreamController<T> controller;
  controller = StreamController<T>(
    sync: true,
    onListen: () {
      try {
        sourceSubscription = source().listen(
          controller.add,
          onError: controller.addError,
          onDone: controller.close,
        );
      } on Object catch (error, stackTrace) {
        controller.addError(error, stackTrace);
        unawaited(controller.close());
      }
    },
    onPause: () => sourceSubscription?.pause(),
    onResume: () => sourceSubscription?.resume(),
    onCancel: () async {
      abort();
      try {
        await sourceSubscription?.cancel();
      } on Object {
        // Aborting an in-flight request completes its pending I/O with an
        // exception, which is expected after the consumer cancels the stream.
      }
    },
  );
  return controller.stream;
}

Map<String, Object?> _openAiMessage(AiChatMessage message) {
  final toolResult = message.toolResult;
  if (toolResult != null) {
    return <String, Object?>{
      'role': 'tool',
      'tool_call_id': toolResult.toolCallId,
      'content': toolResult.content,
    };
  }
  if (message.role == AiChatRole.user && message.attachments.isNotEmpty) {
    return <String, Object?>{
      'role': 'user',
      'content': <Object?>[
        if (message.requestContent.isNotEmpty)
          <String, Object?>{'type': 'text', 'text': message.requestContent},
        for (final attachment in message.attachments)
          if (attachment.kind == AiAttachmentKind.text)
            <String, Object?>{
              'type': 'text',
              'text': _textAttachmentContent(attachment),
            }
          else
            <String, Object?>{
              'type': 'image_url',
              'image_url': <String, Object?>{
                'url':
                    'data:${attachment.mimeType};base64,${attachment.base64Data}',
              },
            },
      ],
    };
  }
  return <String, Object?>{
    'role': message.role.name,
    'content': message.toolCalls.isNotEmpty && message.content.isEmpty
        ? null
        : message.requestContent,
    if (message.toolCalls.isNotEmpty)
      'tool_calls': [
        for (final toolCall in message.toolCalls)
          <String, Object?>{
            'id': toolCall.id,
            'type': 'function',
            'function': <String, Object?>{
              'name': toolCall.name,
              'arguments': jsonEncode(toolCall.arguments),
            },
          },
      ],
  };
}

Map<String, Object?> _anthropicMessage(AiChatMessage message) {
  final toolResult = message.toolResult;
  if (toolResult != null) {
    return <String, Object?>{
      'role': 'user',
      'content': <Object?>[
        <String, Object?>{
          'type': 'tool_result',
          'tool_use_id': toolResult.toolCallId,
          'content': toolResult.content,
          if (toolResult.isError) 'is_error': true,
        },
      ],
    };
  }
  if (message.role == AiChatRole.user && message.attachments.isNotEmpty) {
    return <String, Object?>{
      'role': 'user',
      'content': <Object?>[
        if (message.requestContent.isNotEmpty)
          <String, Object?>{'type': 'text', 'text': message.requestContent},
        for (final attachment in message.attachments)
          if (attachment.kind == AiAttachmentKind.text)
            <String, Object?>{
              'type': 'text',
              'text': _textAttachmentContent(attachment),
            }
          else
            <String, Object?>{
              'type': 'image',
              'source': <String, Object?>{
                'type': 'base64',
                'media_type': attachment.mimeType,
                'data': attachment.base64Data,
              },
            },
      ],
    };
  }
  if (message.toolCalls.isEmpty) {
    return <String, Object?>{
      'role': message.role.name,
      'content': message.requestContent,
    };
  }
  return <String, Object?>{
    'role': 'assistant',
    'content': <Object?>[
      if (message.content.isNotEmpty)
        <String, Object?>{'type': 'text', 'text': message.content},
      for (final toolCall in message.toolCalls)
        <String, Object?>{
          'type': 'tool_use',
          'id': toolCall.id,
          'name': toolCall.name,
          'input': toolCall.arguments,
        },
    ],
  };
}

List<Map<String, Object?>> _anthropicMessages(
  Iterable<AiChatMessage> messages,
) {
  final encoded = <Map<String, Object?>>[];
  List<Object?>? toolResults;

  void flushToolResults() {
    final results = toolResults;
    if (results == null || results.isEmpty) {
      return;
    }
    encoded.add(<String, Object?>{'role': 'user', 'content': results});
    toolResults = null;
  }

  for (final message in messages) {
    if (message.role == AiChatRole.system) {
      continue;
    }
    final toolResult = message.toolResult;
    if (toolResult != null) {
      (toolResults ??= <Object?>[]).add(<String, Object?>{
        'type': 'tool_result',
        'tool_use_id': toolResult.toolCallId,
        'content': toolResult.content,
        if (toolResult.isError) 'is_error': true,
      });
      continue;
    }
    flushToolResults();
    encoded.add(_anthropicMessage(message));
  }
  flushToolResults();
  return encoded;
}

String _textAttachmentContent(AiAttachment attachment) {
  return jsonEncode(<String, Object?>{
    'type': 'text_attachment',
    'name': attachment.name,
    'mime_type': attachment.mimeType,
    'content': attachment.text ?? '',
  });
}

const Map<String, Object?> _terminalCommandParameters = <String, Object?>{
  'type': 'object',
  'properties': <String, Object?>{
    'command': <String, Object?>{
      'type': 'string',
      'description': 'The exact command to run in the active terminal.',
    },
    'explanation': <String, Object?>{
      'type': 'string',
      'description':
          'A concise plain-language explanation of what the command does, why it is needed, and any important risk or side effect.',
    },
  },
  'required': <String>['command', 'explanation'],
  'additionalProperties': false,
};

const Map<String, Object?> _openAiTerminalCommandTool = <String, Object?>{
  'type': 'function',
  'function': <String, Object?>{
    'name': 'run_terminal_command',
    'description':
        'Propose a command with an explanation for the user to review and run in the active terminal.',
    'parameters': _terminalCommandParameters,
  },
};

const Map<String, Object?> _anthropicTerminalCommandTool = <String, Object?>{
  'name': 'run_terminal_command',
  'description':
      'Propose a command with an explanation for the user to review and run in the active terminal.',
  'input_schema': _terminalCommandParameters,
};

class _ToolCallAccumulator {
  String id = '';
  String name = '';
  String arguments = '';

  AiToolCall? toEvent() {
    if (name.isEmpty || arguments.isEmpty) {
      return null;
    }
    try {
      return AiToolCall(id: id, name: name, arguments: _jsonMap(arguments));
    } on FormatException {
      return null;
    }
  }
}

Uri _versionedEndpoint(String baseUrl, String path) {
  final base = Uri.parse(baseUrl.trim());
  final basePath = base.path.replaceFirst(RegExp(r'/+$'), '');
  final hasApiVersion = RegExp(
    r'/(?:v\d+(?:beta\d*)?)(?:/|$)',
  ).hasMatch(basePath);
  final versionedBasePath = hasApiVersion ? basePath : '$basePath/v1';
  return base.replace(path: '$versionedBasePath/$path');
}

Future<void> _throwForError(HttpClientResponse response) async {
  if (response.statusCode >= 200 && response.statusCode < 300) {
    return;
  }
  final body = await response.transform(utf8.decoder).join();
  String? message;
  try {
    final decoded = _jsonMap(body);
    message =
        _nonEmptyString(_nestedMap(decoded['error'])?['message']) ??
        _nonEmptyString(decoded['message']);
  } on FormatException {
    message = null;
  }
  throw AiProtocolException(
    message ?? 'AI request failed with HTTP ${response.statusCode}.',
    statusCode: response.statusCode,
  );
}

Stream<String> _sseData(HttpClientResponse response) async* {
  final dataLines = <String>[];
  await for (final line
      in response.transform(utf8.decoder).transform(const LineSplitter())) {
    if (line.isEmpty) {
      if (dataLines.isNotEmpty) {
        yield dataLines.join('\n');
        dataLines.clear();
      }
      continue;
    }
    if (line.startsWith(':') || !line.startsWith('data:')) {
      continue;
    }
    var data = line.substring(5);
    if (data.startsWith(' ')) {
      data = data.substring(1);
    }
    dataLines.add(data);
  }
  if (dataLines.isNotEmpty) {
    yield dataLines.join('\n');
  }
}

Map<String, Object?> _jsonMap(String source) {
  final decoded = jsonDecode(source);
  if (decoded is! Map) {
    throw const FormatException('Expected a JSON object.');
  }
  return decoded.cast<String, Object?>();
}

Map<String, Object?>? _nestedMap(Object? value) {
  return value is Map ? value.cast<String, Object?>() : null;
}

String? _nonEmptyString(Object? value) {
  if (value is! String || value.isEmpty) {
    return null;
  }
  return value;
}
