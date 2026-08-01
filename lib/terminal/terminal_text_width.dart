/// Returns the number of terminal cells occupied by a single grapheme.
///
/// Terminal emulators use Unicode East Asian width conventions rather than
/// Flutter's glyph metrics. This keeps local Mosh prediction on the same grid
/// as the terminal renderer.
int terminalGraphemeCellWidth(String grapheme) {
  var width = 0;
  for (final rune in grapheme.runes) {
    final runeWidth = _terminalRuneCellWidth(rune);
    if (runeWidth > width) {
      width = runeWidth;
    }
  }
  return width;
}

int _terminalRuneCellWidth(int rune) {
  if (rune == 0 ||
      rune == 0x200c ||
      rune == 0x200d ||
      rune == 0xfe0e ||
      rune == 0xfe0f ||
      (rune >= 0 && rune < 0x20) ||
      (rune >= 0x7f && rune < 0xa0) ||
      (rune >= 0x300 && rune <= 0x36f) ||
      (rune >= 0x1ab0 && rune <= 0x1aff) ||
      (rune >= 0x1dc0 && rune <= 0x1dff) ||
      (rune >= 0x20d0 && rune <= 0x20ff) ||
      (rune >= 0xfe00 && rune <= 0xfe0f) ||
      (rune >= 0xfe20 && rune <= 0xfe2f) ||
      (rune >= 0x1f3fb && rune <= 0x1f3ff) ||
      (rune >= 0xe0100 && rune <= 0xe01ef)) {
    return 0;
  }

  return (rune >= 0x1100 &&
          (rune <= 0x115f ||
              rune == 0x2329 ||
              rune == 0x232a ||
              (rune >= 0x2e80 && rune <= 0xa4cf && rune != 0x303f) ||
              (rune >= 0xac00 && rune <= 0xd7a3) ||
              (rune >= 0xf900 && rune <= 0xfaff) ||
              (rune >= 0xfe10 && rune <= 0xfe19) ||
              (rune >= 0xfe30 && rune <= 0xfe6f) ||
              (rune >= 0xff00 && rune <= 0xff60) ||
              (rune >= 0xffe0 && rune <= 0xffe6) ||
              (rune >= 0x1f000 && rune <= 0x1faff) ||
              (rune >= 0x20000 && rune <= 0x3fffd)))
      ? 2
      : 1;
}
