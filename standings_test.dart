import 'dart:convert';
import 'dart:io';
import 'server.dart';

void check(bool ok, String message) {
  if (!ok) throw StateError(message);
}

Future<void> main() async {
  Json row(String team, String group, String rank) => {
    'leagueId': 'league',
    'teamId': team,
    'teamName': team,
    'leagueRound': group,
    'stageName': 'Group Stage',
    'season': '2026/2027',
    'overallLeaguePosition': rank,
    'overallLeaguePlayed': '3',
    'overallLeagueGF': '2',
    'overallLeagueGA': '5',
    'overallLeaguePTS': '1',
  };
  Json response = {
    'success': true,
    'leagueId': 'league',
    'data': [row('b', 'A', '2'), row('a', 'A', '1'), row('c', 'B', '1')],
  };
  final provider = FootballProvider(
    'unused',
    pageLoader: (_, __) async => response,
  );
  final result = await provider.standings('league');
  final groups = result['groups'] as List;
  check(groups.length == 2, 'Groups must remain separate');
  check(groups[0]['rows'][0]['team']['id'] == 'a', 'Use provider ranking');
  check(groups[0]['rows'][0]['difference'] == -3, 'Signed goal difference');
  check(
    groups[0]['rows'][0]['wins'] == null,
    'Missing values must stay unknown',
  );
  for (final invalid in <Json>[
    {'success': false, 'data': []},
    {'success': true, 'leagueId': 'other', 'data': []},
    {
      'success': true,
      'data': [row('a', 'A', 'bad')],
    },
    {
      'success': true,
      'data': [row('a', 'A', '1'), row('a', 'A', '1')],
    },
    {
      'success': true,
      'data': [],
      'pagination': {'hasMore': true},
    },
  ]) {
    response = invalid;
    var failed = false;
    try {
      await provider.standings('league');
    } on ApiFailure {
      failed = true;
    }
    check(failed, 'Invalid or incomplete table accepted');
  }
  var calls = 0;
  var now = DateTime.utc(2026);
  final cache = GoalEventCache(
    (_) async {
      calls++;
      return result;
    },
    clock: () => now,
    ttl: const Duration(minutes: 15),
  );
  await cache.get('league');
  now = now.add(const Duration(minutes: 14));
  await cache.get('league');
  check(calls == 1, 'Cache must conserve quota');
  now = now.add(const Duration(minutes: 1));
  await cache.get('league');
  check(calls == 2, 'Expired table must reload');
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen(
    (r) => handle(r, FixtureCache((_) async => []), standingsCache: cache),
  );
  final client = HttpClient();
  try {
    final req = await client.getUrl(
      Uri.parse('http://127.0.0.1:${server.port}/leagues/league/standings'),
    );
    final res = await req.close();
    check(res.statusCode == 200, 'Standings route missing');
    final body = jsonDecode(await res.transform(utf8.decoder).join());
    check(
      body['leagueId'] == 'league' && body['cacheSeconds'] == 900,
      'Response contract',
    );
  } finally {
    client.close(force: true);
    await server.close(force: true);
  }
  print(
    'Standings parsing, grouping, unknown values, validation, cache and HTTP tests passed',
  );
}
