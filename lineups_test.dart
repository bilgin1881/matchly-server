import 'dart:convert';
import 'dart:io';
import 'server.dart';

void check(bool ok, String message) {
  if (!ok) throw StateError(message);
}

Future<void> main() async {
  Json response = {
    'success': true,
    'data': {
      'homeFormation': '4-4-2',
      'home': {
        'startingLineups': [
          {
            'lineupPlayer': 'Forward',
            'lineupNumber': '9',
            'lineupPosition': '10',
          },
          {
            'lineupPlayer': 'Keeper',
            'lineupNumber': '1',
            'lineupPosition': '1',
          },
          {
            'lineupPlayer': 'Defender',
            'lineupNumber': '2',
            'lineupPosition': '2',
          },
        ],
        'substitutes': [
          {'lineupPlayer': 'Substitute', 'lineupNumber': '20'},
        ],
      },
      'away': {'startingLineups': [], 'substitutes': []},
    },
  };
  final provider = FootballProvider(
    'test',
    pageLoader: (_, __) async => response,
  );
  final result = await provider.lineups('match');
  final home = result['home'] as Map;
  check(
    (home['starters'] as List).map((p) => p['name']).join(',') ==
        'Keeper,Defender,Forward',
    'Positions must sort numerically',
  );
  check(
    (home['substitutes'] as List).single['name'] == 'Substitute',
    'Bench lost',
  );
  check(home['formation'] == '4-4-2', 'Formation lost');
  check((result['away']['starters'] as List).isEmpty, 'Empty team invented');
  for (final invalid in <Json>[
    {'success': false, 'data': {}},
    {'success': true, 'fixtureId': 'different', 'data': response['data']},
    {
      'success': true,
      'data': {'home': {}, 'away': {}},
    },
  ]) {
    response = invalid;
    var rejected = false;
    try {
      await provider.lineups('match');
    } on ApiFailure {
      rejected = true;
    }
    check(rejected, 'Malformed data must not appear as empty lineup');
  }
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen(
    (request) => handle(
      request,
      FixtureCache((_) async => []),
      lineupCache: GoalEventCache((_) async => result),
    ),
  );
  final client = HttpClient();
  try {
    final request = await client.getUrl(
      Uri.parse('http://127.0.0.1:${server.port}/fixtures/match/lineups'),
    );
    final res = await request.close();
    check(res.statusCode == 200, 'Lineup route unavailable');
    final body = jsonDecode(await res.transform(utf8.decoder).join());
    check(
      body['fixtureId'] == 'match' && body['fetchedAt'] != null,
      'Invalid response',
    );
  } finally {
    client.close(force: true);
    await server.close(force: true);
  }
  print(
    'Lineup parsing, sorting, empty data, malformed data and HTTP tests passed',
  );
}
