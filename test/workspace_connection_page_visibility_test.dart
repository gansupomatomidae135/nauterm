import 'package:flutter_test/flutter_test.dart';
import 'package:nauterm/terminal/terminal_controller.dart';
import 'package:nauterm/workspace/nauterm_workspace.dart';

void main() {
  test('an already-connected rebuilt terminal skips the connection page', () {
    expect(
      shouldBeginConnectionCompletionHold(
        phase: TerminalConnectionPhase.connected,
        previousPhase: null,
        connectionPageWasShown: false,
      ),
      isFalse,
    );
  });

  test('a visible connection page is held while connection completes', () {
    expect(
      shouldBeginConnectionCompletionHold(
        phase: TerminalConnectionPhase.connected,
        previousPhase: TerminalConnectionPhase.connecting,
        connectionPageWasShown: true,
      ),
      isTrue,
    );
  });
}
