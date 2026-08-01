import 'dart:convert';
import 'dart:io' show Platform;

import 'package:http/http.dart' as http;

import 'nauterm_log.dart';

/// Minimal PostHog capture client that talks to the REST API directly.
///
/// Unlike the `posthog_flutter` plugin (which only ships native
/// implementations for iOS, Android, macOS, and Web), this client works on
/// every platform nauterm targets — macOS, Windows, and Linux.
class PostHogAnalytics {
  PostHogAnalytics._();

  static const String _defaultHost = 'https://us.i.posthog.com';

  static String _apiKey = '';
  static String _host = _defaultHost;
  static String _distinctId = '';
  static Map<String, Object> _appProperties = const {};

  static final http.Client _client = http.Client();

  static bool get isEnabled => _apiKey.isNotEmpty && _distinctId.isNotEmpty;

  static void init({
    required String apiKey,
    required String distinctId,
    String host = '',
    String appName = '',
    String appNamespace = '',
    String appVersion = '',
    String appBuild = '',
  }) {
    if (apiKey.isEmpty || distinctId.isEmpty) {
      return;
    }
    _apiKey = apiKey;
    _distinctId = distinctId;
    _host = host.trim().isEmpty
        ? _defaultHost
        : host.trim().replaceFirst(RegExp(r'/+$'), '');
    _appProperties = <String, Object>{
      if (appName.isNotEmpty) '\$app_name': appName,
      if (appNamespace.isNotEmpty) '\$app_namespace': appNamespace,
      if (appVersion.isNotEmpty) '\$app_version': appVersion,
      if (appBuild.isNotEmpty) '\$app_build': appBuild,
    };
  }

  /// Sends an event and reports whether PostHog accepted it.
  ///
  /// Failures are converted to `false` so analytics can never affect the app.
  static Future<bool> capture(
    String event, [
    Map<String, Object>? properties,
  ]) async {
    if (!isEnabled) {
      return false;
    }
    return _send(event, properties ?? const <String, Object>{});
  }

  /// Records the visible application screen using PostHog's standard event.
  static Future<bool> screen(String name) {
    return capture(r'$screen', <String, Object>{r'$screen_name': name});
  }

  static Future<bool> _send(
    String event,
    Map<String, Object> properties,
  ) async {
    try {
      final payload = <String, Object?>{
        'api_key': _apiKey,
        'event': event,
        'distinct_id': _distinctId,
        'properties': <String, Object?>{
          '\$os': Platform.operatingSystem,
          ..._appProperties,
          ...properties,
          r'$geoip_disable': true,
        },
        'timestamp': DateTime.now().toUtc().toIso8601String(),
      };
      final response = await _client
          .post(
            Uri.parse('$_host/i/v0/e/'),
            headers: const {'Content-Type': 'application/json'},
            body: jsonEncode(payload),
          )
          .timeout(const Duration(seconds: 5));
      final accepted = response.statusCode >= 200 && response.statusCode < 300;
      if (accepted) {
        NautermLog.info(
          'analytics',
          'PostHog accepted an event.',
          fields: {'event': event, 'http_status': response.statusCode},
        );
      } else {
        NautermLog.warning(
          'analytics',
          'PostHog rejected an event.',
          fields: {'event': event, 'http_status': response.statusCode},
        );
      }
      return accepted;
    } on Object catch (error, stackTrace) {
      // Never let analytics affect the app.
      NautermLog.warning(
        'analytics',
        'PostHog failed to send an event.',
        error: error,
        stackTrace: stackTrace,
        fields: {'event': event},
      );
      return false;
    }
  }
}
