import 'server.dart';
import 'goal_provider_test.dart' as sample;

void check(bool ok, String message) {
  if (!ok) throw StateError(message);
}

Future<void> main() async {
  var now = DateTime.utc(2026, 10, 16);
  var calls = 0;
  final cache = GoalEventCache(
    (id) async {
      calls++;
      return {'fixtureId': id};
    },
    clock: () => now,
    ttl: const Duration(minutes: 1),
  );
  await cache.get('m');
  now = now.add(const Duration(seconds: 29));
  await cache.get('m', refresh: true);
  check(calls == 1, 'Manual refresh ignored 30-second floor');
  now = now.add(const Duration(seconds: 1));
  await Future.wait([
    cache.get('m', refresh: true),
    cache.get('m', refresh: true),
  ]);
  check(calls == 2, 'Concurrent manual refresh was not shared');
  now = now.add(const Duration(seconds: 59));
  await cache.get('m');
  check(calls == 2, 'Lineup cache expired too early');
  now = now.add(const Duration(seconds: 1));
  await cache.get('m');
  check(calls == 3, 'Lineup cache did not expire at one minute');
  final provider = FootballProvider(
    'test',
    pageLoader: (_, __) async => {
      'success': true,
      'data': sample.row('m', status: 'LIVE', period: 'FIRST_HALF'),
    },
  );
  final score = (await provider.fixture('m'))['fixture'] as Map;
  check(
    score['id'] == 'm' &&
        score['home']['name'] == 'Galatasaray' &&
        score['goals']['home'] == 3 &&
        score['status'] == '1H',
    'Score schema mismatch',
  );
  var dayCalls = 0;
  final days = FixtureCache(
    (_) async {
      dayCalls++;
      return [];
    },
    clock: () => now,
    interval: Duration.zero,
    liveInterval: const Duration(seconds: 30),
  );
  await days.get('2026-10-16', live: true);
  now = now.add(const Duration(seconds: 29));
  await days.get('2026-10-16', live: true);
  check(dayCalls == 1, 'Live cache expired too soon');
  now = now.add(const Duration(seconds: 1));
  await days.get('2026-10-16', live: true);
  check(dayCalls == 2, 'Live cache did not expire');
  print(
    'Refresh throttling, deduplication, TTL and score contract tests passed',
  );
}
