import 'dart:convert';
import 'dart:io';

import 'server.dart';

void check(bool condition, String message) {
  if (!condition) throw StateError(message);
}

Json sample({
  int id = 42,
  int league = 89288,
  String state = 'Not started',
  String? score,
}) => {
  'id': id,
  'date': '2026-10-13T22:00:00Z',
  'country': {'name': 'Turkey'},
  'league': {'id': league},
  'homeTeam': {
    'id': 1,
    'name': 'Home',
    'logo': 'https://highlightly.net/basketball/images/teams/1.png',
  },
  'awayTeam': {'id': 2, 'name': 'Away'},
  'state': {
    'description': state,
    'score': {'current': score},
  },
};
Future<void> main() async {
  final window = Window(
    DateTime.utc(2026, 10, 13, 21),
    DateTime.utc(2026, 10, 14, 21),
  );
  final upcoming = normalize([basketballRow(sample())], window).single;
  check(
    upcoming['id'] == 'hl-basket-42' && upcoming['sport'] == 'basketball',
    'Namespaced sport identity',
  );
  check(
    asMap(upcoming['goals'])['home'] == null && upcoming['status'] == 'NS',
    'Unknown score remains null',
  );
  check(asMap(upcoming['home'])['logo'] != null, 'Logo preserved');
  final live = normalize([
    basketballRow(sample(state: 'Third quarter', score: '71 - 65')),
  ], window).single;
  check(
    live['status'] == 'Q3' && liveStatuses.contains(live['status']),
    'Quarter status is live',
  );
  check(
    asMap(live['goals'])['home'] == 71 && asMap(live['goals'])['away'] == 65,
    'Basketball score',
  );
  check(live['elapsed'] == null, 'No football minute clock');
  final finished = normalize([
    basketballRow(
      sample(state: 'Finished after over time', score: '110 - 105'),
    ),
  ], window).single;
  check(finished['status'] == 'AET', 'Overtime completion');
  check(
    normalize([
      basketballRow(sample()),
    ], Window(DateTime.utc(2026, 10, 14), DateTime.utc(2026, 10, 15))).isEmpty,
    'UTC window excludes previous day',
  );
  final offsets = <int>[];
  final provider = BasketballProvider(
    'test',
    dailyLimit: 2,
    pageLoader: (day, offset) async {
      offsets.add(offset);
      return {
        'data': offset == 0
            ? List.generate(100, (i) => sample(id: i, league: 999))
            : [sample()],
        'pagination': {'totalCount': 101, 'offset': offset, 'limit': 100},
        'plan': {'message': 'All data available with current plan.'},
      };
    },
  );
  check(
    (await provider.fetch('2026-10-13')).length == 1 &&
        offsets.join(',') == '0,100',
    'Filter only after full pagination',
  );
  try {
    await provider.fetch('2026-10-14');
    throw StateError('Quota bypass');
  } on ApiFailure catch (e) {
    check(e.code == 'daily_limit', 'Physical page quota');
  }
  final restricted = BasketballProvider(
    'test',
    pageLoader: (_, offset) async => {
      'data': [],
      'pagination': {'totalCount': 0, 'offset': offset, 'limit': 100},
      'plan': {'message': 'Some results might be hidden'},
    },
  );
  try {
    await restricted.fetch('2026-10-13');
    throw StateError('Hidden data accepted');
  } on ApiFailure catch (e) {
    check(e.code == 'provider_plan', 'Plan restriction');
  }
  var now = DateTime.utc(2026, 10, 13);
  var calls = 0;
  final cache = FixtureCache(
    (_) async {
      calls++;
      return [];
    },
    clock: () => now,
    interval: Duration.zero,
    fixedCacheMinutes: 120,
  );
  await cache.get('2026-10-13', live: true);
  now = now.add(const Duration(minutes: 119));
  await cache.get('2026-10-13', live: true);
  check(calls == 1, 'Live requests must respect two-hour cache');
  now = now.add(const Duration(minutes: 1));
  await cache.get('2026-10-13');
  check(calls == 2, 'Cache refresh at two hours');
  // HTTP contract, including optional configuration and old football route.
  final football = FixtureCache((_) async => [], interval: Duration.zero);
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  FixtureCache? basketball;
  final subscription = server.listen(
    (request) => handle(request, football, basketballCache: basketball),
  );
  final client = HttpClient();
  try {
    final start = DateTime.now().toUtc();
    final params = {
      'start': start.toIso8601String(),
      'end': start.add(const Duration(days: 1)).toIso8601String(),
    };
    for (final path in ['/basketball/fixtures', '/fixtures']) {
      final req = await client.getUrl(
        Uri.http('127.0.0.1:${server.port}', path, params),
      );
      final res = await req.close();
      final body = jsonDecode(await res.transform(utf8.decoder).join());
      if (path.startsWith('/basketball')) {
        check(
          res.statusCode == 503 && body['error'] == 'basketball_not_configured',
          'Missing basketball config is explicit',
        );
      } else {
        check(
          res.statusCode == 200,
          'Football remains available without basketball key',
        );
      }
    }
    basketball = FixtureCache(
      (_) async => [
        basketballRow(
          sample()
            ..['date'] = start.add(const Duration(hours: 1)).toIso8601String(),
        ),
      ],
      interval: Duration.zero,
      fixedCacheMinutes: 120,
    );
    final req = await client.getUrl(
      Uri.http('127.0.0.1:${server.port}', '/basketball/fixtures', params),
    );
    final res = await req.close();
    final body = jsonDecode(await res.transform(utf8.decoder).join());
    check(
      res.statusCode == 200 &&
          body['cacheMinutes'] == 120 &&
          body['source'] == 'highlightly',
      'Basketball HTTP metadata',
    );
    check(
      (body['fixtures'] as List).length == 1 &&
          body['fixtures'][0]['sport'] == 'basketball',
      'Basketball HTTP fixtures',
    );
  } finally {
    client.close(force: true);
    await subscription.cancel();
    await server.close(force: true);
  }
  print('Basketball provider tests passed');
}
