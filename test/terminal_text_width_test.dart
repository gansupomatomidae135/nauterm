import 'package:flutter_test/flutter_test.dart';
import 'package:nauterm/terminal/terminal_text_width.dart';

void main() {
  test('uses terminal cell widths for common local prediction graphemes', () {
    expect(terminalGraphemeCellWidth('a'), 1);
    expect(terminalGraphemeCellWidth('你'), 2);
    expect(terminalGraphemeCellWidth('🙂'), 2);
    expect(terminalGraphemeCellWidth('e\u0301'), 1);
    expect(terminalGraphemeCellWidth('👩‍💻'), 2);
  });
}
