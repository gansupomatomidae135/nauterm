import 'package:flutter_test/flutter_test.dart';
import 'package:nauterm/terminal/terminal_driver.dart';

void main() {
  test('memory terminal scrolls its fixed-size cell buffer', () {
    final driver = MemoryTerminalDriver(columns: 2, rows: 2);

    expect(() => driver.write('abcd'), returnsNormally);
    expect(driver.snapshot.cells.map((cell) => cell.text), [
      'c',
      'd',
      ' ',
      ' ',
    ]);
  });
}
