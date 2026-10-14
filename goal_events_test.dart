import 'dart:async';
import 'dart:io';
import 'dart:convert';

import 'server.dart';

void check(bool ok, String message) {
  if (!ok) throw StateError(message);
}

Future<void> main() async {
  var calls = 0;
  final provider = FootballProvider(
    'test',
    dailyLimit: 2,
    pageLoader: (_, __) async {
      calls++;
      return {
        'success': true,
        'fixtureId': 'match',
        'data': [
          {
            'id': 'one',
            'type': 'GOAL',
            'time': '90+6',
            'homeScorer': 'M. Lemina',
            'homeAssist': 'V. Osimhen',
            'score': '3 - 1',
          },
          {'id': 'one', 'type': 'GOAL', 'time': '90+6'},
          {'id': 'two', 'type': 'CARD', 'time': '89'},
        ],
      };
    },
  );
  var now = DateTime.utc(2026, 10, 14);
  final cache = GoalEventCache(provider.events, clock: () => now);
  final results = await Future.wait([cache.get('match'), cache.get('match')]);
  check(calls == 1, 'Concurrent requests were not deduplicated');
  final goal = (results.first['goals'] as List).single as Map;
  check(
    goal['time'] == '90+6' &&
        goal['homeScorer'] == 'M. Lemina' &&
        goal['homeAssist'] == 'V. Osimhen',
    'Goal data lost',
  );
  await cache.get('match');
  check(calls == 1, 'Cache missed');
  now = now.add(const Duration(minutes: 5));
  await cache.get('match');
  check(calls == 2, 'Cache failed to expire');
  now = now.add(const Duration(minutes: 5));
  try {
    await cache.get('match');
    throw StateError('Quota ignored');
  } on ApiFailure catch (e) {
    check(e.code == 'daily_limit', 'Wrong quota error');
  }

  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final fixtureCache = FixtureCache((_) async => []);
  final httpEvents = GoalEventCache(
    (id) async => {'fixtureId': id, 'goals': []},
  );
  server.listen(
    (request) => handle(request, fixtureCache, goalEvents: httpEvents),
  );
  final client = HttpClient();
  try {
    final req = await client.getUrl(
      Uri.parse('http://127.0.0.1:${server.port}/fixtures/match/events'),
    );
    final res = await req.close();
    check(res.statusCode == 200, 'Events route unavailable');
    final body = jsonDecode(await res.transform(utf8.decoder).join());
    check(
      body['fixtureId'] == 'match' && body['goals'] is List,
      'Invalid response contract',
    );
  } finally {
    client.close(force: true);
    await server.close(force: true);
  }
  print(
    'Goal event parsing, deduplication, cache, quota and HTTP tests passed',
  );
}
