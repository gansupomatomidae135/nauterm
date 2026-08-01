import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import '../app/nauterm_log.dart';

enum CloudOAuthVendor { googleCloudStorage, googleDrive, oneDrive, dropbox }

class CloudOAuthCredentials {
  const CloudOAuthCredentials({
    required this.clientId,
    required this.refreshToken,
    this.clientSecret,
  });

  final String clientId;
  final String refreshToken;
  final String? clientSecret;

  Map<String, String> toMap() => <String, String>{
    'client_id': clientId,
    'refresh_token': refreshToken,
    'client_secret': ?clientSecret,
  };
}

class CloudOAuthException implements Exception {
  const CloudOAuthException(this.message);

  final String message;

  @override
  String toString() => message;
}

class CloudOAuthClient {
  CloudOAuthClient({http.Client? httpClient})
    : _httpClient = httpClient ?? http.Client(),
      _ownsHttpClient = httpClient == null;

  final http.Client _httpClient;
  final bool _ownsHttpClient;

  Future<CloudOAuthCredentials> authorize(CloudOAuthVendor vendor) async {
    final operation = NautermLog.begin(
      'oauth',
      'Cloud OAuth authorization',
      fields: {'provider': vendor.name},
    );
    try {
      final credentials = await _authorize(vendor);
      operation.succeed();
      return credentials;
    } on Object catch (error, stackTrace) {
      operation.fail(error, stackTrace: stackTrace);
      rethrow;
    }
  }

  Future<CloudOAuthCredentials> _authorize(CloudOAuthVendor vendor) async {
    final config = _CloudOAuthConfig.forVendor(vendor);
    if (config.clientId.isEmpty) {
      throw CloudOAuthException(
        '${config.label} OAuth is not configured. Build with '
        '--dart-define=${config.clientIdEnvironmentName}=your_client_id.',
      );
    }
    final server = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      config.callbackPort,
    );
    final redirectUri = Uri(
      scheme: 'http',
      host: config.callbackHost,
      port: server.port,
      path: config.callbackPath,
    );
    final verifier = _randomUrlSafeText(64);
    final challenge = _base64UrlNoPadding(
      sha256.convert(utf8.encode(verifier)).bytes,
    );
    final state = _randomUrlSafeText(32);
    final authorizationUri = config.authorizationUri.replace(
      queryParameters: <String, String>{
        'client_id': config.clientId,
        'redirect_uri': redirectUri.toString(),
        'response_type': 'code',
        if (config.scopes.isNotEmpty) 'scope': config.scopes.join(' '),
        'state': state,
        'code_challenge': challenge,
        'code_challenge_method': 'S256',
        ...config.authorizationParameters,
      },
    );

    try {
      await _openBrowser(authorizationUri);
      final request = await server
          .firstWhere((request) => request.uri.path == config.callbackPath)
          .timeout(const Duration(minutes: 5));
      final parameters = request.uri.queryParameters;
      await _respondToBrowser(request, parameters['error'] == null);
      if (parameters['state'] != state) {
        throw const CloudOAuthException(
          'OAuth callback state did not match the authorization request.',
        );
      }
      if (parameters['error'] case final error?) {
        throw CloudOAuthException(
          parameters['error_description'] ?? 'OAuth was denied: $error.',
        );
      }
      final code = parameters['code'];
      if (code == null || code.isEmpty) {
        throw const CloudOAuthException(
          'OAuth callback did not contain an authorization code.',
        );
      }
      final response = await _httpClient.post(
        config.tokenUri,
        headers: const {
          'Accept': 'application/json',
          'Content-Type': 'application/x-www-form-urlencoded',
        },
        body: <String, String>{
          'grant_type': 'authorization_code',
          'client_id': config.clientId,
          if (config.clientSecret.isNotEmpty)
            'client_secret': config.clientSecret,
          'code': code,
          'redirect_uri': redirectUri.toString(),
          'code_verifier': verifier,
        },
      );
      final payload = _decodeTokenResponse(response, config.label);
      final accessToken = payload['access_token'] as String?;
      final refreshToken = payload['refresh_token'] as String?;
      if (accessToken == null ||
          accessToken.isEmpty ||
          refreshToken == null ||
          refreshToken.isEmpty) {
        throw CloudOAuthException(
          '${config.label} did not return both access and refresh tokens.',
        );
      }
      return CloudOAuthCredentials(
        clientId: config.clientId,
        refreshToken: refreshToken,
        clientSecret: config.clientSecret.isEmpty ? null : config.clientSecret,
      );
    } on TimeoutException {
      throw const CloudOAuthException('OAuth authorization timed out.');
    } finally {
      await server.close(force: true);
    }
  }

  void close() {
    if (_ownsHttpClient) _httpClient.close();
  }

  static Map<String, dynamic> _decodeTokenResponse(
    http.Response response,
    String label,
  ) {
    Object? decoded;
    try {
      decoded = jsonDecode(response.body);
    } on FormatException {
      throw CloudOAuthException(
        '$label returned an invalid OAuth token response.',
      );
    }
    if (decoded is! Map<String, dynamic>) {
      throw CloudOAuthException(
        '$label returned an invalid OAuth token response.',
      );
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw CloudOAuthException(
        decoded['error_description'] as String? ??
            decoded['error_summary'] as String? ??
            decoded['error']?.toString() ??
            '$label OAuth failed with HTTP ${response.statusCode}.',
      );
    }
    return decoded;
  }
}

class _CloudOAuthConfig {
  const _CloudOAuthConfig({
    required this.label,
    required this.clientId,
    required this.clientIdEnvironmentName,
    this.clientSecret = '',
    this.callbackPort = 0,
    this.callbackHost = '127.0.0.1',
    this.callbackPath = '/oauth/callback',
    required this.authorizationUri,
    required this.tokenUri,
    required this.scopes,
    this.authorizationParameters = const <String, String>{},
  });

  factory _CloudOAuthConfig.forVendor(CloudOAuthVendor vendor) {
    return switch (vendor) {
      CloudOAuthVendor.googleCloudStorage => _CloudOAuthConfig(
        label: 'Google Cloud Storage',
        clientId: _oauthSetting('NAUTERM_GOOGLE_CLIENT_ID'),
        clientIdEnvironmentName: 'NAUTERM_GOOGLE_CLIENT_ID',
        clientSecret: _oauthSetting('NAUTERM_GOOGLE_CLIENT_SECRET'),
        authorizationUri: Uri.parse(
          'https://accounts.google.com/o/oauth2/v2/auth',
        ),
        tokenUri: Uri.parse('https://oauth2.googleapis.com/token'),
        scopes: const ['https://www.googleapis.com/auth/devstorage.read_write'],
        authorizationParameters: const {
          'access_type': 'offline',
          'prompt': 'consent',
        },
      ),
      CloudOAuthVendor.googleDrive => _CloudOAuthConfig(
        label: 'Google Drive',
        clientId: _oauthSetting('NAUTERM_GOOGLE_CLIENT_ID'),
        clientIdEnvironmentName: 'NAUTERM_GOOGLE_CLIENT_ID',
        clientSecret: _oauthSetting('NAUTERM_GOOGLE_CLIENT_SECRET'),
        authorizationUri: Uri.parse(
          'https://accounts.google.com/o/oauth2/v2/auth',
        ),
        tokenUri: Uri.parse('https://oauth2.googleapis.com/token'),
        scopes: const ['https://www.googleapis.com/auth/drive.file'],
        authorizationParameters: const {
          'access_type': 'offline',
          'prompt': 'consent',
        },
      ),
      CloudOAuthVendor.oneDrive => _CloudOAuthConfig(
        label: 'OneDrive',
        clientId: _oauthSetting('NAUTERM_ONEDRIVE_CLIENT_ID'),
        clientIdEnvironmentName: 'NAUTERM_ONEDRIVE_CLIENT_ID',
        callbackHost: 'localhost',
        callbackPath: '/',
        authorizationUri: Uri.parse(
          'https://login.microsoftonline.com/common/oauth2/v2.0/authorize',
        ),
        tokenUri: Uri.parse(
          'https://login.microsoftonline.com/common/oauth2/v2.0/token',
        ),
        scopes: const ['offline_access', 'Files.ReadWrite'],
      ),
      CloudOAuthVendor.dropbox => _CloudOAuthConfig(
        label: 'Dropbox',
        clientId: _oauthSetting('NAUTERM_DROPBOX_CLIENT_ID'),
        clientIdEnvironmentName: 'NAUTERM_DROPBOX_CLIENT_ID',
        callbackPort: 53682,
        authorizationUri: Uri.parse('https://www.dropbox.com/oauth2/authorize'),
        tokenUri: Uri.parse('https://api.dropboxapi.com/oauth2/token'),
        scopes: const [],
        authorizationParameters: const {'token_access_type': 'offline'},
      ),
    };
  }

  final String label;
  final String clientId;
  final String clientIdEnvironmentName;
  final String clientSecret;
  final int callbackPort;
  final String callbackHost;
  final String callbackPath;
  final Uri authorizationUri;
  final Uri tokenUri;
  final List<String> scopes;
  final Map<String, String> authorizationParameters;
}

String _oauthSetting(String name) {
  final compiled = switch (name) {
    'NAUTERM_GOOGLE_CLIENT_ID' => const String.fromEnvironment(
      'NAUTERM_GOOGLE_CLIENT_ID',
    ),
    'NAUTERM_GOOGLE_CLIENT_SECRET' => const String.fromEnvironment(
      'NAUTERM_GOOGLE_CLIENT_SECRET',
    ),
    'NAUTERM_ONEDRIVE_CLIENT_ID' => const String.fromEnvironment(
      'NAUTERM_ONEDRIVE_CLIENT_ID',
    ),
    'NAUTERM_DROPBOX_CLIENT_ID' => const String.fromEnvironment(
      'NAUTERM_DROPBOX_CLIENT_ID',
    ),
    _ => '',
  };
  if (compiled.trim().isNotEmpty) return compiled.trim();
  return Platform.environment[name]?.trim() ?? '';
}

String _randomUrlSafeText(int byteCount) {
  final random = math.Random.secure();
  return _base64UrlNoPadding(
    List<int>.generate(byteCount, (_) => random.nextInt(256)),
  );
}

String _base64UrlNoPadding(List<int> bytes) =>
    base64UrlEncode(bytes).replaceAll('=', '');

Future<void> _openBrowser(Uri uri) async {
  if (Platform.isMacOS) {
    await Process.start('open', [
      uri.toString(),
    ], mode: ProcessStartMode.detached);
  } else if (Platform.isWindows) {
    await Process.start('rundll32', [
      'url.dll,FileProtocolHandler',
      uri.toString(),
    ], mode: ProcessStartMode.detached);
  } else {
    await Process.start('xdg-open', [
      uri.toString(),
    ], mode: ProcessStartMode.detached);
  }
}

Future<void> _respondToBrowser(HttpRequest request, bool success) async {
  request.response.headers.contentType = ContentType.html;
  request.response.write(
    '<!doctype html><meta charset="utf-8"><title>Nauterm</title>'
    '<body style="font:16px system-ui;padding:40px">'
    '<h2>${success ? 'Authorization complete' : 'Authorization failed'}</h2>'
    '<p>You can close this window and return to Nauterm.</p></body>',
  );
  await request.response.close();
}
