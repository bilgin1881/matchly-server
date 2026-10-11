import 'server.dart';

void check(bool value, String message) {
  if (!value) throw StateError(message);
}

Json row(String id, {String status = 'FINISHED', String period = 'FINISHED'}) =>
    {
      'id': id,
      'leagueId': superLigId,
      'kickoffUtc': '2026-10-09T17:00:00Z',
      'matchStatus': status,
      'matchPeriod': period,
      'matchLive': '1',
      'homeTeamId': 'gs',
      'awayTeamId': 'kas',
      'homeTeam': {'name': 'Galatasaray'},
      'awayTeam': {'name': 'Kasımpaşa'},
      'homeTeamScore': '3',
      'awayTeamScore': '1',
    };
Future<void> main() async {
  final window = Window(DateTime.utc(2026, 10, 9), DateTime.utc(2026, 10, 10));
  final fixture = normalize([goalRow(row('match'))], window).single;
  check(fixture['status'] == 'FT', 'Legacy live flag must not override FT');
  check(asMap(fixture['goals'])['home'] == 3, 'String score conversion');
  final missing = row('missing')..['homeTeamScore'] = null;
  check(
    asMap(goalRow(missing)['goals'])['home'] == null,
    'Null score must stay unknown',
  );
  check(
    asMap(
          goalRow(
            row('live', status: 'LIVE', period: 'SECOND_HALF'),
          )['fixture'],
        )['status']['short'] ==
        '2H',
    'Live period',
  );
  check(
    asMap(
          goalRow(
            row('p', status: 'POSTPONED', period: 'NOT_STARTED'),
          )['fixture'],
        )['status']['short'] ==
        'PST',
    'Terminal status precedence',
  );
  final offsets = <int>[];
  final provider = FootballProvider(
    'test',
    dailyLimit: 2,
    pageLoader: (day, offset) async {
      offsets.add(offset);
      return {
        'success': true,
        'data': offset == 0
            ? [row('other')..['leagueId'] = 'other']
            : [row('match')],
        'pagination': {'offset': offset, 'limit': 100, 'hasMore': offset == 0},
      };
    },
  );
  final rows = await provider.fetch('2026-10-09');
  check(
    rows.length == 1 && offsets.join(',') == '0,100',
    'Filter must include later pages',
  );
  try {
    await provider.fetch('2026-10-10');
    throw StateError('Per-page quota bypassed');
  } on ApiFailure catch (e) {
    check(e.code == 'daily_limit', 'Quota category');
  }
  final partial = FootballProvider(
    'test',
    pageLoader: (day, offset) async {
      if (offset > 0) throw const ApiFailure('provider_limit', 429);
      return {
        'success': true,
        'data': [row('match')],
        'pagination': {'offset': offset, 'limit': 100, 'hasMore': true},
      };
    },
  );
  try {
    await partial.fetch('2026-10-09');
    throw StateError('Partial results accepted');
  } on ApiFailure catch (e) {
    check(e.code == 'provider_limit', 'Partial failure propagation');
  }
  print('GOAL provider tests passed');
}
