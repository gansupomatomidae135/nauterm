import 'package:flutter_test/flutter_test.dart';
import 'package:nauterm/ai/ai_conversation.dart';
import 'package:nauterm/terminal/terminal_controller.dart';
import 'package:nauterm/terminal/terminal_driver.dart';
import 'package:nauterm/workspace/terminal_lifecycle_service.dart';

void main() {
  test('terminal disposal is idempotent by controller identity', () {
    final released = <AiConversationController>[];
    final service = TerminalLifecycleService(releaseConversation: released.add);
    final driver = _TrackingTerminalDriver();
    final controller = TerminalController(driver: driver);

    service.disposeTerminal(controller);
    service.disposeTerminal(controller);

    expect(controller.isDisposed, isTrue);
    expect(driver.disposeCount, 1);
    expect(released, isEmpty);
  });

  test('conversation persistence is released before one disposal', () {
    final events = <String>[];
    final service = TerminalLifecycleService(
      releaseConversation: (_) => events.add('release'),
    );
    final conversation = _TrackingConversation(events);

    service.disposeConversation(conversation);
    service.disposeConversation(conversation);

    expect(events, ['release', 'dispose']);
    expect(conversation.disposeCount, 1);
  });
}

class _TrackingTerminalDriver extends MemoryTerminalDriver {
  _TrackingTerminalDriver() : super(columns: 80, rows: 24);

  int disposeCount = 0;

  @override
  void dispose() {
    disposeCount += 1;
    super.dispose();
  }
}

class _TrackingConversation extends AiConversationController {
  _TrackingConversation(this.events);

  final List<String> events;
  int disposeCount = 0;

  @override
  void dispose() {
    disposeCount += 1;
    events.add('dispose');
    super.dispose();
  }
}
