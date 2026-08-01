import 'dart:async';

import 'package:flutter/services.dart';

enum NautermFileDropEventType { dragging, dropped, exited }

class NautermFileDropEvent {
  const NautermFileDropEvent({
    required this.type,
    this.paths = const [],
    this.x,
    this.y,
  });

  final NautermFileDropEventType type;
  final List<String> paths;
  final double? x;
  final double? y;
}

class NautermFileDropChannel {
  NautermFileDropChannel._();

  static final NautermFileDropChannel instance = NautermFileDropChannel._();

  static const MethodChannel _channel = MethodChannel(
    'com.korvect.nauterm/file_drop',
  );

  final StreamController<NautermFileDropEvent> _events =
      StreamController<NautermFileDropEvent>.broadcast();
  bool _initialized = false;

  Stream<NautermFileDropEvent> get events => _events.stream;

  void ensureInitialized() {
    if (_initialized) {
      return;
    }
    _initialized = true;
    _channel.setMethodCallHandler(_handleMethodCall);
  }

  Future<void> setEnabled(bool enabled) async {
    ensureInitialized();
    try {
      await _channel.invokeMethod<void>('setEnabled', {'enabled': enabled});
    } on MissingPluginException {
      // File drop is only implemented by desktop runners that opt into it.
    }
  }

  Future<Object?> _handleMethodCall(MethodCall call) async {
    switch (call.method) {
      case 'filesDragging':
        _events.add(
          NautermFileDropEvent(
            type: NautermFileDropEventType.dragging,
            x: _coordinateFromArguments(call.arguments, 'x'),
            y: _coordinateFromArguments(call.arguments, 'y'),
          ),
        );
        return null;
      case 'filesDropped':
        final paths = _pathsFromArguments(call.arguments);
        if (paths.isNotEmpty) {
          _events.add(
            NautermFileDropEvent(
              type: NautermFileDropEventType.dropped,
              paths: paths,
              x: _coordinateFromArguments(call.arguments, 'x'),
              y: _coordinateFromArguments(call.arguments, 'y'),
            ),
          );
        }
        return null;
      case 'filesExited':
        _events.add(
          const NautermFileDropEvent(type: NautermFileDropEventType.exited),
        );
        return null;
      default:
        throw MissingPluginException(
          'Unknown file drop method: ${call.method}',
        );
    }
  }

  List<String> _pathsFromArguments(Object? arguments) {
    final Object? rawPaths = arguments is Map ? arguments['paths'] : arguments;
    if (rawPaths is! List) {
      return const [];
    }
    return [
      for (final path in rawPaths)
        if (path is String && path.trim().isNotEmpty) path,
    ];
  }

  double? _coordinateFromArguments(Object? arguments, String key) {
    if (arguments is! Map) {
      return null;
    }
    final value = arguments[key];
    if (value is num) {
      return value.toDouble();
    }
    return null;
  }
}
