import 'package:flutter_test/flutter_test.dart';
import 'package:nauterm/terminal/terminal_ffi.dart';
import 'package:nauterm/terminal/terminal_models.dart';

void main() {
  test('preserves Mosh input state numbers in connection events', () {
    final event = TerminalConnectionEvent.fromJson({
      'kind': 'mosh_prediction_confirmed',
      'message': 'confirmed',
      'state_num': 17,
    });

    expect(event.kind, TerminalConnectionEventKind.moshPredictionConfirmed);
    expect(event.stateNum, 17);
    expect(event.copyWith(stateNum: 18).stateNum, 18);
  });

  test('recognizes queued Mosh input state events', () {
    final event = TerminalConnectionEvent.fromJson({
      'kind': 'mosh_input_state_queued',
      'message': 'queued',
      'state_num': 4,
    });

    expect(event.kind, TerminalConnectionEventKind.moshInputStateQueued);
    expect(event.stateNum, 4);
  });

  test('recognizes committed Mosh screen state events', () {
    final event = TerminalConnectionEvent.fromJson({
      'kind': 'mosh_screen_committed',
      'message': 'screen committed',
      'state_num': 9,
    });

    expect(event.kind, TerminalConnectionEventKind.moshScreenCommitted);
    expect(event.stateNum, 9);
  });

  test('recognizes SSH latency updates', () {
    final event = TerminalConnectionEvent.fromJson({
      'kind': 'ssh_latency_updated',
      'message': 'SSH latency 3 ms.',
      'latency_ms': 3,
    });

    expect(event.kind, TerminalConnectionEventKind.sshLatencyUpdated);
    expect(event.latencyMs, 3);
  });

  test('preserves SFTP host key events when listing fails', () {
    final result = FfiSftpDirectoryEntryListing.decodeResult({
      'entries': const [],
      'error': 'Unknown host key.',
      'events': [
        {
          'kind': 'host_key_unknown',
          'message': 'The server host key is unknown.',
          'host': 'example.com',
          'port': 22,
          'fingerprint': 'SHA256:test',
        },
      ],
    });

    expect(result.isError, isTrue);
    expect(result.events, hasLength(1));
    expect(
      result.events.single.kind,
      TerminalConnectionEventKind.hostKeyUnknown,
    );
    expect(result.events.single.fingerprint, 'SHA256:test');
  });
}
