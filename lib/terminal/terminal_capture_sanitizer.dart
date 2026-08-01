import 'dart:typed_data';

const int _escape = 0x1b;
const int _osc = 0x5d;
const int _bell = 0x07;
const int _stringTerminator = 0x5c;
const int _semicolon = 0x3b;
const int _maxPendingOscBytes = 64 * 1024;
const Set<String> _internalOscCodes = {'7', '133', '4545', '777'};

/// Removes Nauterm implementation details from terminal bytes before capture.
///
/// Raw output listeners still receive the original stream so hidden shell
/// setup can complete its marker handshake. Only the persisted capture passes
/// through this sanitizer.
class TerminalCaptureSanitizer {
  final List<int> _suppressionPending = [];
  final List<int> _oscPending = [];
  List<int>? _suppressionMarker;

  void suppressUntil(Uint8List marker) {
    _suppressionPending.clear();
    _suppressionMarker = marker.isEmpty ? null : marker.toList(growable: false);
  }

  void cancelSuppression() {
    _suppressionPending.clear();
    _suppressionMarker = null;
  }

  Uint8List add(Uint8List chunk) {
    if (chunk.isEmpty) return Uint8List(0);

    List<int> input = chunk;
    final marker = _suppressionMarker;
    if (marker != null) {
      _suppressionPending.addAll(chunk);
      final markerIndex = _indexOfBytes(_suppressionPending, marker);
      if (markerIndex < 0) {
        final retain = marker.length - 1;
        if (_suppressionPending.length > retain) {
          _suppressionPending.removeRange(
            0,
            _suppressionPending.length - retain,
          );
        }
        return Uint8List(0);
      }
      input = _suppressionPending.sublist(markerIndex + marker.length);
      _suppressionPending.clear();
      _suppressionMarker = null;
    }

    return _stripInternalOsc(input);
  }

  Uint8List close() {
    _suppressionPending.clear();
    _suppressionMarker = null;
    final remaining = Uint8List.fromList(_oscPending);
    _oscPending.clear();
    return remaining;
  }

  Uint8List _stripInternalOsc(List<int> bytes) {
    final input = <int>[..._oscPending, ...bytes];
    _oscPending.clear();
    final output = BytesBuilder(copy: false);
    var index = 0;

    while (index < input.length) {
      final start = _indexOfOsc(input, index);
      if (start < 0) {
        final retainEscape = input.last == _escape;
        final end = retainEscape ? input.length - 1 : input.length;
        if (end > index) output.add(input.sublist(index, end));
        if (retainEscape) _oscPending.add(_escape);
        break;
      }
      if (start > index) output.add(input.sublist(index, start));

      final terminator = _oscTerminator(input, start + 2);
      if (terminator == null) {
        _oscPending.addAll(input.sublist(start));
        if (_oscPending.length > _maxPendingOscBytes) {
          output.add(_oscPending);
          _oscPending.clear();
        }
        break;
      }

      final payloadEnd = terminator.$1;
      final sequenceEnd = payloadEnd + terminator.$2;
      final separator = input.indexOf(_semicolon, start + 2);
      final codeEnd = separator >= 0 && separator < payloadEnd
          ? separator
          : payloadEnd;
      final code = String.fromCharCodes(input.sublist(start + 2, codeEnd));
      if (!_internalOscCodes.contains(code)) {
        output.add(input.sublist(start, sequenceEnd));
      }
      index = sequenceEnd;
    }

    return output.takeBytes();
  }
}

int _indexOfBytes(List<int> input, List<int> needle) {
  if (needle.isEmpty) return 0;
  for (var index = 0; index + needle.length <= input.length; index++) {
    var matches = true;
    for (var offset = 0; offset < needle.length; offset++) {
      if (input[index + offset] != needle[offset]) {
        matches = false;
        break;
      }
    }
    if (matches) return index;
  }
  return -1;
}

int _indexOfOsc(List<int> input, int start) {
  for (var index = start; index + 1 < input.length; index++) {
    if (input[index] == _escape && input[index + 1] == _osc) return index;
  }
  return -1;
}

(int, int)? _oscTerminator(List<int> input, int start) {
  for (var index = start; index < input.length; index++) {
    if (input[index] == _bell) return (index, 1);
    if (input[index] == _escape &&
        index + 1 < input.length &&
        input[index + 1] == _stringTerminator) {
      return (index, 2);
    }
  }
  return null;
}
