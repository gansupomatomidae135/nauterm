import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../app/nauterm_log.dart';

const String _compiledGithubClientId = String.fromEnvironment(
  'NAUTERM_GITHUB_CLIENT_ID',
);

String? githubDeviceFlowClientIdOverride;

String get githubDeviceFlowClientId {
  if (githubDeviceFlowClientIdOverride != null) {
    return githubDeviceFlowClientIdOverride!.trim();
  }
  if (_compiledGithubClientId.trim().isNotEmpty) {
    return _compiledGithubClientId.trim();
  }
  final environmentClientId =
      Platform.environment['NAUTERM_GITHUB_CLIENT_ID']?.trim() ?? '';
  return environmentClientId;
}

class GithubDeviceFlowException implements Exception {
  const GithubDeviceFlowException(this.message);

  final String message;

  @override
  String toString() => message;
}

class GithubDeviceFlowSession {
  const GithubDeviceFlowSession({
    required this.deviceCode,
    required this.userCode,
    required this.verificationUri,
    required this.expiresAt,
    required this.interval,
  });

  final String deviceCode;
  final String userCode;
  final Uri verificationUri;
  final DateTime expiresAt;
  final Duration interval;
}

enum GithubDeviceFlowPollStatus {
  pending,
  slowDown,
  authorized,
  expired,
  denied,
}

class GithubDeviceFlowPollResult {
  const GithubDeviceFlowPollResult._({
    required this.status,
    this.accessToken,
    this.scope,
    this.errorDescription,
    this.interval,
  });

  const GithubDeviceFlowPollResult.pending()
    : this._(status: GithubDeviceFlowPollStatus.pending);

  const GithubDeviceFlowPollResult.slowDown({Duration? interval})
    : this._(status: GithubDeviceFlowPollStatus.slowDown, interval: interval);

  const GithubDeviceFlowPollResult.authorized({
    required String accessToken,
    String? scope,
  }) : this._(
         status: GithubDeviceFlowPollStatus.authorized,
         accessToken: accessToken,
         scope: scope,
       );

  const GithubDeviceFlowPollResult.expired({String? errorDescription})
    : this._(
        status: GithubDeviceFlowPollStatus.expired,
        errorDescription: errorDescription,
      );

  const GithubDeviceFlowPollResult.denied({String? errorDescription})
    : this._(
        status: GithubDeviceFlowPollStatus.denied,
        errorDescription: errorDescription,
      );

  final GithubDeviceFlowPollStatus status;
  final String? accessToken;
  final String? scope;
  final String? errorDescription;
  final Duration? interval;
}

class GithubDeviceFlowClient {
  GithubDeviceFlowClient({required this.clientId, http.Client? httpClient})
    : _httpClient = httpClient ?? http.Client(),
      _ownsHttpClient = httpClient == null;

  static final Uri _deviceCodeUri = Uri.parse(
    'https://github.com/login/device/code',
  );
  static final Uri _accessTokenUri = Uri.parse(
    'https://github.com/login/oauth/access_token',
  );
  static final Uri _userUri = Uri.parse('https://api.github.com/user');

  final String clientId;
  final http.Client _httpClient;
  final bool _ownsHttpClient;

  Future<GithubDeviceFlowSession> start({
    String scope = 'gist read:user',
  }) async {
    final operation = NautermLog.begin('oauth', 'GitHub Device Flow start');
    try {
      final session = await _start(scope);
      operation.succeed(
        fields: {
          'expires_in_seconds': session.expiresAt
              .difference(DateTime.now())
              .inSeconds,
        },
      );
      return session;
    } on Object catch (error, stackTrace) {
      operation.fail(error, stackTrace: stackTrace);
      rethrow;
    }
  }

  Future<GithubDeviceFlowSession> _start(String scope) async {
    if (clientId.trim().isEmpty) {
      throw const GithubDeviceFlowException(
        'GitHub Device Flow is not configured. Build with '
        '--dart-define=NAUTERM_GITHUB_CLIENT_ID=your_client_id.',
      );
    }
    final response = await _httpClient.post(
      _deviceCodeUri,
      headers: const {
        'Accept': 'application/json',
        'Content-Type': 'application/x-www-form-urlencoded',
      },
      body: {'client_id': clientId, 'scope': scope},
    );
    final data = _decodeResponse(response, operation: 'start Device Flow');
    final deviceCode = data['device_code'] as String?;
    final userCode = data['user_code'] as String?;
    final verificationUri = Uri.tryParse(
      data['verification_uri'] as String? ?? '',
    );
    final expiresIn = _readPositiveInt(data['expires_in']);
    final interval = _readPositiveInt(data['interval']) ?? 5;
    if (deviceCode == null ||
        deviceCode.isEmpty ||
        userCode == null ||
        userCode.isEmpty ||
        verificationUri == null ||
        expiresIn == null) {
      throw const GithubDeviceFlowException(
        'GitHub returned an incomplete Device Flow response.',
      );
    }
    return GithubDeviceFlowSession(
      deviceCode: deviceCode,
      userCode: userCode,
      verificationUri: verificationUri,
      expiresAt: DateTime.now().add(Duration(seconds: expiresIn)),
      interval: Duration(seconds: interval < 5 ? 5 : interval),
    );
  }

  Future<GithubDeviceFlowPollResult> poll(String deviceCode) async {
    final response = await _httpClient.post(
      _accessTokenUri,
      headers: const {
        'Accept': 'application/json',
        'Content-Type': 'application/x-www-form-urlencoded',
      },
      body: {
        'client_id': clientId,
        'device_code': deviceCode,
        'grant_type': 'urn:ietf:params:oauth:grant-type:device_code',
      },
    );
    final data = _decodeResponse(response, operation: 'poll Device Flow');
    final accessToken = data['access_token'] as String?;
    if (accessToken != null && accessToken.isNotEmpty) {
      NautermLog.info(
        'oauth',
        'GitHub authorization state changed.',
        fields: const {'status': 'authorized'},
      );
      return GithubDeviceFlowPollResult.authorized(
        accessToken: accessToken,
        scope: data['scope'] as String?,
      );
    }
    final error = data['error'] as String?;
    final description = data['error_description'] as String?;
    final result = switch (error) {
      'authorization_pending' => const GithubDeviceFlowPollResult.pending(),
      'slow_down' => GithubDeviceFlowPollResult.slowDown(
        interval: switch (_readPositiveInt(data['interval'])) {
          final seconds? => Duration(seconds: seconds),
          null => null,
        },
      ),
      'expired_token' => GithubDeviceFlowPollResult.expired(
        errorDescription: description,
      ),
      'access_denied' => GithubDeviceFlowPollResult.denied(
        errorDescription: description,
      ),
      final String value => throw GithubDeviceFlowException(
        description ?? 'GitHub Device Flow failed: $value.',
      ),
      null => throw const GithubDeviceFlowException(
        'GitHub returned an invalid Device Flow polling response.',
      ),
    };
    if (result.status != GithubDeviceFlowPollStatus.pending) {
      final fields = {'status': result.status.name};
      if (result.status == GithubDeviceFlowPollStatus.authorized) {
        NautermLog.info(
          'oauth',
          'GitHub authorization state changed.',
          fields: fields,
        );
      } else {
        NautermLog.warning(
          'oauth',
          'GitHub authorization state changed.',
          fields: fields,
        );
      }
    }
    return result;
  }

  Future<String> loadUserLogin(String accessToken) async {
    final operation = NautermLog.begin('oauth', 'Validate GitHub account');
    try {
      final response = await _httpClient.get(
        _userUri,
        headers: {
          'Accept': 'application/vnd.github+json',
          'Authorization': 'Bearer $accessToken',
          'X-GitHub-Api-Version': '2022-11-28',
        },
      );
      final data = _decodeResponse(
        response,
        operation: 'validate the authorized GitHub account',
      );
      final login = data['login'] as String?;
      if (login == null || login.isEmpty) {
        throw const GithubDeviceFlowException(
          'GitHub did not return the authorized account.',
        );
      }
      operation.succeed();
      return login;
    } on Object catch (error, stackTrace) {
      operation.fail(error, stackTrace: stackTrace);
      rethrow;
    }
  }

  void close() {
    if (_ownsHttpClient) {
      _httpClient.close();
    }
  }

  static Map<String, dynamic> _decodeResponse(
    http.Response response, {
    required String operation,
  }) {
    Object? decoded;
    try {
      decoded = jsonDecode(response.body);
    } on FormatException {
      throw GithubDeviceFlowException(
        'GitHub could not $operation (${response.statusCode}).',
      );
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final data = decoded is Map<String, dynamic> ? decoded : null;
      final description =
          data?['error_description'] as String? ??
          data?['error'] as String? ??
          response.reasonPhrase;
      throw GithubDeviceFlowException(
        'GitHub could not $operation (${response.statusCode})'
        '${description == null ? '.' : ': $description'}',
      );
    }
    if (decoded is! Map<String, dynamic>) {
      throw GithubDeviceFlowException(
        'GitHub returned an invalid response while trying to $operation.',
      );
    }
    return decoded;
  }

  static int? _readPositiveInt(Object? value) {
    final number = switch (value) {
      int value => value,
      String value => int.tryParse(value),
      _ => null,
    };
    return number != null && number > 0 ? number : null;
  }
}
