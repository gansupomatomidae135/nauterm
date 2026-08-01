import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nauterm/settings/github_device_flow.dart';

void main() {
  test(
    'GitHub Device Flow requests gist scope and polls authorization',
    () async {
      var pollCount = 0;
      final httpClient = MockClient((request) async {
        if (request.url.path == '/user') {
          expect(request.method, 'GET');
          expect(request.headers['authorization'], 'Bearer oauth-token');
          return http.Response(jsonEncode({'login': 'octocat'}), 200);
        }
        expect(request.method, 'POST');
        expect(request.headers['accept'], 'application/json');
        final body = Uri.splitQueryString(request.body);
        expect(body['client_id'], 'client-id');
        if (request.url.path == '/login/device/code') {
          expect(body['scope'], 'gist read:user');
          return http.Response(
            jsonEncode({
              'device_code': 'device-code',
              'user_code': 'ABCD-EFGH',
              'verification_uri': 'https://github.com/login/device',
              'expires_in': 900,
              'interval': 3,
            }),
            200,
          );
        }
        expect(request.url.path, '/login/oauth/access_token');
        expect(
          body['grant_type'],
          'urn:ietf:params:oauth:grant-type:device_code',
        );
        expect(body['device_code'], 'device-code');
        pollCount++;
        if (pollCount == 1) {
          return http.Response(
            jsonEncode({'error': 'authorization_pending'}),
            200,
          );
        }
        return http.Response(
          jsonEncode({
            'access_token': 'oauth-token',
            'token_type': 'bearer',
            'scope': 'gist,read:user',
          }),
          200,
        );
      });
      final client = GithubDeviceFlowClient(
        clientId: 'client-id',
        httpClient: httpClient,
      );

      final session = await client.start();
      expect(session.userCode, 'ABCD-EFGH');
      expect(session.interval, const Duration(seconds: 5));

      final pending = await client.poll(session.deviceCode);
      expect(pending.status, GithubDeviceFlowPollStatus.pending);

      final authorized = await client.poll(session.deviceCode);
      expect(authorized.status, GithubDeviceFlowPollStatus.authorized);
      expect(authorized.accessToken, 'oauth-token');
      expect(authorized.scope, 'gist,read:user');
      expect(await client.loadUserLogin('oauth-token'), 'octocat');
      client.close();
    },
  );

  test('GitHub Device Flow applies slow_down interval', () async {
    final client = GithubDeviceFlowClient(
      clientId: 'client-id',
      httpClient: MockClient(
        (_) async => http.Response(
          jsonEncode({'error': 'slow_down', 'interval': 12}),
          200,
        ),
      ),
    );

    final result = await client.poll('device-code');
    expect(result.status, GithubDeviceFlowPollStatus.slowDown);
    expect(result.interval, const Duration(seconds: 12));
    client.close();
  });

  test('GitHub Device Flow requires a configured client id', () async {
    final client = GithubDeviceFlowClient(
      clientId: '',
      httpClient: MockClient((_) async => http.Response('{}', 500)),
    );

    await expectLater(
      client.start(),
      throwsA(
        isA<GithubDeviceFlowException>().having(
          (error) => error.message,
          'message',
          contains('NAUTERM_GITHUB_CLIENT_ID'),
        ),
      ),
    );
    client.close();
  });
}
