import 'dart:typed_data';

const List<int> _zshPromptEolMarker = [
  0x1b,
  0x5b,
  0x37,
  0x6d,
  0x25,
  0x1b,
  0x5b,
  0x32,
  0x37,
  0x6d,
];
const List<int> _restorePrimaryScreen = [
  0x1b,
  0x5b,
  0x3f,
  0x31,
  0x30,
  0x34,
  0x39,
  0x6c,
];

class TerminalReplaySanitizer {
  final List<int> _pending = [];

  Uint8List add(Uint8List chunk) {
    if (chunk.isEmpty) {
      return Uint8List(0);
    }

    final input = <int>[..._pending, ...chunk];
    _pending.clear();
    final output = BytesBuilder(copy: false);
    var index = 0;

    while (index < input.length) {
      if (_matchesMarkerAt(input, index)) {
        index += _zshPromptEolMarker.length;
        continue;
      }

      final remaining = input.length - index;
      if (remaining < _zshPromptEolMarker.length &&
          _matchesMarkerPrefix(input, index)) {
        _pending.addAll(input.sublist(index));
        break;
      }

      output.addByte(input[index]);
      index++;
    }

    return output.takeBytes();
  }

  Uint8List close({bool restorePrimaryScreen = false}) {
    final remaining = Uint8List.fromList([
      ..._pending,
      if (restorePrimaryScreen) ..._restorePrimaryScreen,
    ]);
    _pending.clear();
    return remaining;
  }

  bool _matchesMarkerAt(List<int> input, int start) {
    if (input.length - start < _zshPromptEolMarker.length) {
      return false;
    }
    for (var index = 0; index < _zshPromptEolMarker.length; index++) {
      if (input[start + index] != _zshPromptEolMarker[index]) {
        return false;
      }
    }
    return true;
  }

  bool _matchesMarkerPrefix(List<int> input, int start) {
    final length = input.length - start;
    for (var index = 0; index < length; index++) {
      if (input[start + index] != _zshPromptEolMarker[index]) {
        return false;
      }
    }
    return true;
  }
}
