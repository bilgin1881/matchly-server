import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'server.dart';

void check(bool condition, String message) {
  if (!condition) throw StateError(message);
}

Future<void> main() async {
  const token = 'synthetic-client-token-for-tests-00000000';
  final config = ServerConfig.fromEnvironment({
    'RENDER_EXTERNAL_HOSTNAME': 'matchly-test.onrender.com',
    'MATCHLY_CLIENT_TOKEN': token, 'PORT': '10000',
  });
  check(config.public && config.address.address == '0.0.0.0' && config.port == 10000,
    'Cloud server does not bind to the platform port');
  final local = ServerConfig.fromEnvironment({});
  check(!local.public && local.address.isLoopback && local.port == 8787,
    'Default local mode changed');
  for (final env in <Map<String, String>>[
    {'MATCHLY_PUBLIC_SERVER': 'true'},
    {'RENDER_EXTERNAL_HOSTNAME': 'matchly-test.onrender.com', 'MATCHLY_CLIENT_TOKEN': 'short'},
    {'RENDER_EXTERNAL_HOSTNAME': 'https://example.com', 'MATCHLY_CLIENT_TOKEN': token},
    {'RENDER_EXTERNAL_HOSTNAME': 'example.com', 'MATCHLY_CLIENT_TOKEN': token, 'PORT': 'no'},
  ]) {
    try {
      ServerConfig.fromEnvironment(env);
      throw StateError('Invalid cloud configuration was accepted');
    } on ApiFailure catch (error) {
      check(error.code == 'invalid_cloud_config', 'Wrong configuration error');
    }
  }
  check(!config.authorized(null) && !config.authorized('Bearer wrong') &&
    config.authorized('Bearer $token'), 'Cloud authentication failed');
  check(!const ServerConfig(public: true).authorized('Bearer '), 'Empty token was accepted');
  check(!local.acceptsHost('matchly-test.onrender.com'), 'Local mode accepted a public host');
  // Exercise the real HTTP handler with a fake provider; these tests never use API quota.
  var calls = 0;
  final cache = FixtureCache((_) async { calls++; return []; }, interval: Duration.zero);
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final subscription = server.listen((request) => unawaited(handle(request, cache, config: config)));
  final client = HttpClient();
  Future<(int, Json, HttpHeaders)> get(String path, {String? authorization,
      String host = 'matchly-test.onrender.com', String? origin, String method = 'GET'}) async {
    final request = await client.openUrl(method, Uri.parse('http://127.0.0.1:${server.port}$path'));
    request.headers.set('host', host);
    if (authorization != null) request.headers.set('authorization', authorization);
    if (origin != null) request.headers.set('origin', origin);
    final response = await request.close();
    final body = await utf8.decoder.bind(response).join();
    return (response.statusCode, body.isEmpty ? <String, dynamic>{} : asMap(jsonDecode(body)), response.headers);
  }
  try {
    final health = await get('/health');
    check(health.$1 == 200 && health.$2['status'] == 'ok' &&
      !health.$2.containsKey('lastProviderError') && !health.$2.containsKey('coverage'),
      'Public health exposed diagnostics');
    final authorizedHealth = await get('/health', authorization: 'Bearer $token');
    check(authorizedHealth.$2.containsKey('coverage') && calls == 0,
      'Authenticated health consumed provider quota or lost coverage');
    final unauthorized = await get('/fixtures');
    check(unauthorized.$1 == 401 && unauthorized.$2['error'] == 'client_auth' && calls == 0,
      'Unauthorized traffic reached the provider');
    final wrong = await get('/fixtures', authorization: 'Bearer wrong');
    check(wrong.$1 == 401 && calls == 0, 'Wrong token reached the provider');
    final now = DateTime.now().toUtc();
    final day = DateTime.utc(now.year, now.month, now.day);
    final path = Uri(path: '/fixtures', queryParameters: {
      'start': day.toIso8601String(), 'end': day.add(const Duration(days: 1)).toIso8601String(),
    }).toString();
    final accepted = await get(path, authorization: 'Bearer $token');
    check(accepted.$1 == 200 && (accepted.$2['fixtures'] as List).isEmpty && calls == 1,
      'Authorized cloud fixtures failed');
    await get(path, authorization: 'Bearer $token');
    check(calls == 1, 'Cloud requests bypassed the shared cache');
    final badHost = await get(path, host: 'untrusted.example', authorization: 'Bearer $token');
    check(badHost.$1 == 403 && calls == 1, 'Untrusted host was accepted');
    final badOrigin = await get(path, origin: 'https://untrusted.example', authorization: 'Bearer $token');
    check(badOrigin.$1 == 403 && calls == 1, 'Untrusted browser origin was accepted');
    final preflight = await get('/fixtures', origin: 'http://localhost:8788', method: 'OPTIONS');
    check(preflight.$1 == 204 &&
      preflight.$3.value('access-control-allow-headers')!.contains('authorization') && calls == 1,
      'Local browser preflight cannot use the client token');
    check(!jsonEncode(accepted.$2).contains(token), 'Response exposed the client token');
  } finally {
    client.close(force: true);
    await subscription.cancel();
    await server.close(force: true);
  }
  stdout.writeln('Cloud configuration and HTTP access tests passed.');
}
