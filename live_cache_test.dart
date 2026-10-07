import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'server.dart';

void check(bool condition, String message) {
  if (!condition) throw StateError(message);
}

Json row(String date, String status) => {
  'fixture': {'id': 1, 'date': date, 'status': {'short': status, 'elapsed': 12}},
  'teams': {'home': {'id': 1, 'name': 'Home'}, 'away': {'id': 2, 'name': 'Away'}},
  'league': {'id': 3, 'name': 'League', 'country': 'Turkey'},
  'goals': {'home': 1, 'away': 0},
};

Future<void> main() async {
  var now = DateTime.utc(2026, 10, 7, 12);
  var calls = 0;
  final cache = FixtureCache((_) async { calls++; return []; },
    clock: () => now, interval: Duration.zero, dailyLimit: 2);
  await cache.get('2026-10-07');
  now = now.add(const Duration(minutes: 4, seconds: 59));
  await cache.get('2026-10-07', live: true);
  check(calls == 1, 'Live cache expired before five minutes.');
  now = now.add(const Duration(seconds: 1));
  await cache.get('2026-10-07');
  check(calls == 1, 'Normal schedule did not keep its fifteen-minute cache.');
  await Future.wait([cache.get('2026-10-07', live: true), cache.get('2026-10-07', live: true)]);
  check(calls == 2, 'Concurrent live refreshes did not share one provider request.');
  now = now.add(const Duration(minutes: 5));
  try {
    await cache.get('2026-10-07', live: true);
    throw StateError('Live requests bypassed the shared daily cap.');
  } on ApiFailure catch (e) { check(e.code == 'daily_limit', 'Unexpected cap error.'); }
  await cache.get('2026-10-07');
  check(calls == 2, 'An available normal cache was lost after a live quota failure.');

  now = DateTime.utc(2026, 10, 8, 0, 10);
  var state = '1H';
  var crossCalls = 0;
  final cross = FixtureCache((_) async {
    crossCalls++;
    return [row('2026-10-07T23:50:00Z', state)];
  }, clock: () => now, interval: Duration.zero);
  await cross.get('2026-10-07', live: true);
  check(cross.cacheMinutesFor('2026-10-07', live: true) == 5,
    'A live match across UTC midnight was treated as a completed day.');
  now = now.add(const Duration(minutes: 5));
  state = 'FT';
  await cross.get('2026-10-07', live: true);
  check(crossCalls == 2 && cross.cacheMinutesFor('2026-10-07', live: true) == 15,
    'A finished previous-day match kept consuming five-minute requests.');
  check(cross.cacheMinutesFor('2026-10-09', live: true) == 15,
    'Live mode shortened a future date’s cache.');
  state = 'NS';
  final newlyStarted = FixtureCache((_) async => [row('2026-10-07T23:50:00Z', state)],
    clock: () => now, interval: Duration.zero);
  await newlyStarted.get('2026-10-07');
  check(newlyStarted.cacheMinutesFor('2026-10-07', live: true) == 5,
    'A recently scheduled match missed its start across UTC midnight.');

  // Verify the real authorized HTTP response and timestamp selection. An old,
  // finished date must not make the active match’s data time look stale.
  var httpTime = DateTime.now().toUtc();
  final today = DateTime.utc(httpTime.year, httpTime.month, httpTime.day);
  final todayKey = today.toIso8601String().substring(0, 10);
  final previous = today.subtract(const Duration(days: 1));
  final previousKey = previous.toIso8601String().substring(0, 10);
  var httpCalls = 0;
  final httpCache = FixtureCache((day) async {
    httpCalls++;
    return [row((day == todayKey ? today : previous).add(const Duration(minutes: 1)).toIso8601String(),
      day == todayKey ? '1H' : 'FT')];
  }, clock: () => httpTime, interval: Duration.zero);
  await httpCache.get(previousKey);
  httpTime = httpTime.add(const Duration(minutes: 6));
  const token = 'synthetic-client-token-for-live-tests-000000';
  const config = ServerConfig(public: true, publicHost: 'matchly-test.onrender.com', clientToken: token);
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final subscription = server.listen((request) => unawaited(handle(request, httpCache, config: config)));
  final client = HttpClient();
  Future<(int, Json)> request(String? mode) async {
    final url = Uri(scheme: 'http', host: '127.0.0.1', port: server.port, path: '/fixtures',
      queryParameters: {'start': previous.add(const Duration(hours: 12)).toIso8601String(),
        'end': today.add(const Duration(hours: 12)).toIso8601String(), if (mode != null) 'live': mode});
    final req = await client.getUrl(url);
    req.headers.set('host', config.publicHost);
    req.headers.set('authorization', 'Bearer $token');
    final response = await req.close();
    return (response.statusCode, asMap(jsonDecode(await utf8.decoder.bind(response).join())));
  }
  try {
    final live = await request('1');
    check(live.$1 == 200 && live.$2['cacheMinutes'] == 5, 'Live HTTP metadata was lost.');
    check(DateTime.parse(live.$2['liveFetchedAt'] as String) == httpTime,
      'An old finished date hid the active match’s actual data time.');
    check(DateTime.parse(live.$2['fetchedAt'] as String).isBefore(httpTime),
      'The complete schedule’s oldest timestamp was rewritten as fresh.');
    final normal = await request(null);
    check(normal.$2['cacheMinutes'] == 15 && !normal.$2.containsKey('liveFetchedAt'),
      'Normal HTTP cache behavior changed.');
    final count = httpCalls;
    final invalid = await request('0');
    check(invalid.$1 == 400 && httpCalls == count, 'Invalid mode consumed quota.');
  } finally {
    client.close(force: true);
    await subscription.cancel();
    await server.close(force: true);
  }
  print('Live five-minute cache, midnight, deduplication, quota and HTTP timestamp checks passed.');
}
