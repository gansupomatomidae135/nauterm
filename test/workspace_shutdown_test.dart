import 'package:flutter_test/flutter_test.dart';
import 'package:nauterm/workspace/nauterm_workspace.dart';

void main() {
  test('workspace shutdown is idempotent without an attached view', () async {
    final controller = NautermWorkspaceController();
    addTearDown(controller.dispose);

    final first = controller.flushAndClose();
    final second = controller.flushAndClose();

    expect(identical(first, second), isTrue);
    await first;
  });
}
