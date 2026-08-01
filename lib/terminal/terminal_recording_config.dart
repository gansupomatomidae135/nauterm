import 'package:flutter/foundation.dart';

@immutable
class NautermRecordingConfig {
  const NautermRecordingConfig({
    this.enabled = true,
    this.captureEnabled = false,
    this.retentionDays = 30,
    this.maxSessionBytes = 100 * 1024 * 1024,
    this.maxTotalBytes = 2 * 1024 * 1024 * 1024,
  });

  final bool enabled;
  final bool captureEnabled;
  final int retentionDays;
  final int maxSessionBytes;
  final int maxTotalBytes;

  factory NautermRecordingConfig.fromJson(Object? value) {
    final json = value is Map
        ? value.cast<String, Object?>()
        : const <String, Object?>{};
    return NautermRecordingConfig(
      enabled: json['enabled'] as bool? ?? true,
      captureEnabled: json['captureEnabled'] as bool? ?? false,
      retentionDays: (json['retentionDays'] as num?)?.toInt() ?? 30,
      maxSessionBytes:
          (json['maxSessionBytes'] as num?)?.toInt() ?? 100 * 1024 * 1024,
      maxTotalBytes:
          (json['maxTotalBytes'] as num?)?.toInt() ?? 2 * 1024 * 1024 * 1024,
    );
  }

  Map<String, Object?> toJson() => {
    'enabled': enabled,
    'captureEnabled': captureEnabled,
    'retentionDays': retentionDays,
    'maxSessionBytes': maxSessionBytes,
    'maxTotalBytes': maxTotalBytes,
  };

  NautermRecordingConfig copyWith({
    bool? enabled,
    bool? captureEnabled,
    int? retentionDays,
    int? maxSessionBytes,
    int? maxTotalBytes,
  }) {
    return NautermRecordingConfig(
      enabled: enabled ?? this.enabled,
      captureEnabled: captureEnabled ?? this.captureEnabled,
      retentionDays: retentionDays ?? this.retentionDays,
      maxSessionBytes: maxSessionBytes ?? this.maxSessionBytes,
      maxTotalBytes: maxTotalBytes ?? this.maxTotalBytes,
    );
  }
}
