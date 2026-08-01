import 'package:flutter_test/flutter_test.dart';
import 'package:nauterm/settings/cloud_oauth.dart';

void main() {
  test('OAuth credentials omit an absent client secret', () {
    const credentials = CloudOAuthCredentials(
      clientId: 'desktop-client',
      refreshToken: 'refresh-token',
    );

    expect(credentials.toMap(), const <String, String>{
      'client_id': 'desktop-client',
      'refresh_token': 'refresh-token',
    });
  });

  test('OAuth credentials preserve a configured client secret', () {
    const credentials = CloudOAuthCredentials(
      clientId: 'web-client',
      refreshToken: 'refresh-token',
      clientSecret: 'client-secret',
    );

    expect(credentials.toMap(), const <String, String>{
      'client_id': 'web-client',
      'refresh_token': 'refresh-token',
      'client_secret': 'client-secret',
    });
  });
}
