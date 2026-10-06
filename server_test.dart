import 'dart:async';
import 'server.dart';

void check(bool condition, String message) {
  if (!condition) throw StateError(message);
}

Map<String, dynamic> raw(int id, String date) => {
  'fixture': {'id': id, 'date': date, 'status': {'short': 'PST', 'elapsed': null}},
  'teams': {'home': {'id': 1, 'name': 'Home'}, 'away': {'id': 2, 'name': 'Away'}},
  'league': {'id': 3, 'name': 'League', 'country': 'Turkey'},
  'goals': {'home': null, 'away': null},
};

Future<void> main() async {
  final now = DateTime.utc(2026, 10, 2, 18);
  final window = Window.parse({'start': '2026-10-01T21:00:00Z',
    'end': '2026-10-02T21:00:00Z'}, now);
  check(window.utcDays.join(',') == '2026-10-01,2026-10-02', 'Istanbul day must span two UTC dates');
  final normalized = normalize([
    raw(1, '2026-10-01T20:59:59Z'), raw(2, '2026-10-01T21:00:00Z'),
    raw(2, '2026-10-01T21:00:00Z'), raw(3, '2026-10-02T21:00:00Z'),
    raw(4, 'not-a-date'),
  ], window);
  check(normalized.length == 1 && normalized.single['id'] == '2', 'Half-open window and deduplication failed');
  check(normalized.single['status'] == 'PST', 'Postponed status was lost');
  check((normalized.single['goals'] as Map)['home'] == null, 'Unknown goals became zero');
  try {
    Window.parse({'start': '2026-10-02T00:00:00Z', 'end': '2027-01-01T00:00:00Z'}, now);
    throw StateError('An oversized date window was accepted');
  } on ApiFailure catch (error) { check(error.status == 400, 'Wrong invalid-window status'); }

  final distant = Window.parse({'start': '2026-10-15T21:00:00Z',
    'end': '2026-10-16T21:00:00Z'}, now);
  check(distant.utcDays.length == 2, 'A complete upcoming weekly digest cannot load its last day');
  try {
    Window.parse({'start': '2026-10-19T00:00:00Z', 'end': '2026-10-20T00:00:00Z'}, now);
    throw StateError('The digest horizon bound was bypassed');
  } on ApiFailure catch (error) { check(error.status == 400, 'Wrong horizon error'); }

  final providerCases = <dynamic, String>{
    {'token': 'Invalid API key'}: 'provider_auth',
    ['Your API key is missing']: 'provider_auth',
    {'plan': 'Free plans do not have access to this date'}: 'provider_plan',
    {'requests': 'Daily quota reached'}: 'provider_limit',
    {'rateLimit': 'Too many requests'}: 'provider_limit',
    {'date': 'Invalid date'}: 'provider_parameters',
    {'other': 'Unrecognized error'}: 'provider_access',
  };
  for (final entry in providerCases.entries) {
    check(classifyProviderError(entry.key).code == entry.value,
      'Provider error category mismatch: ${entry.value}');
  }
  const secret = 'synthetic-key-not-a-real-credential';
  final safe = classifyProviderError({'token': 'Invalid API key: $secret'});
  check(safe.code == 'provider_auth' && !safe.code.contains(secret),
    'Provider diagnostics exposed a credential');

  final dateScope = classifyProviderError({'plan':
    'Free plans do not have access to this date, try from 2026-10-01 to 2026-10-03.'});
  check(dateScope.details['reason'] == 'date_scope' &&
    dateScope.details['allowedFrom'] == '2026-10-01' &&
    dateScope.details['allowedTo'] == '2026-10-03', 'Allowed date bounds were not extracted');
  final seasonScope = classifyProviderError({'plan': 'Allowed seasons from 2022 to 2024.'});
  check(seasonScope.details['allowedSeasonFrom'] == 2022 &&
    seasonScope.details['allowedSeasonTo'] == 2024, 'Allowed season bounds were not extracted');
  final redacted = classifyProviderError({'plan':
    'Free plans do not have access to this date. Credential: from 2026-10-01 to 2026-10-03'},
    secret: 'from 2026-10-01 to 2026-10-03');
  check(!redacted.details.containsKey('allowedFrom'), 'Secret was interpreted as a date scope');
  final inactive = classifyProviderError({'plan': 'Your subscription is inactive'});
  check(inactive.details['reason'] == 'subscription_state', 'Inactive subscription was not identified');
  final diagnosticCache = FixtureCache((_) async { throw dateScope; },
    clock: () => now, interval: Duration.zero);
  try {
    await diagnosticCache.get('2026-10-04');
    throw StateError('A failed provider request was cached as successful data');
  } on ApiFailure {
    check(diagnosticCache.lastProviderFailure?['requestedUtcDate'] == '2026-10-04',
      'Rejected UTC date was not retained');
    check(diagnosticCache.lastProviderFailure?['allowedTo'] == '2026-10-03',
      'Safe provider plan bounds were not retained');
    check(!diagnosticCache.lastProviderFailure!.containsKey('message'),
      'Diagnostics exposed a raw provider message');
  }

  var coverageTime = now;
  var blockedCalls = 0;
  final limitedCache = FixtureCache((_) async {
    blockedCalls++;
    throw classifyProviderError({'plan':
      'Free plans do not have access to this date, try from 2026-10-01 to 2026-10-03.'});
  }, clock: () => coverageTime, interval: Duration.zero);
  for (final day in ['2026-10-04', '2026-10-05']) {
    try { await limitedCache.get(day); }
    on ApiFailure catch (error) { check(error.code == 'provider_plan', 'Wrong scope error'); }
  }
  check(blockedCalls == 1, 'A known closed date consumed another upstream request');
  check(limitedCache.providerCoverage?['to'] == '2026-10-03', 'Allowed end date lost');
  coverageTime = DateTime.utc(2026, 10, 3, 1);
  check(limitedCache.providerCoverage == null, 'A stale UTC-day scope survived rollover');
  try { await limitedCache.get('2026-10-05'); }
  on ApiFailure catch (_) {}
  check(blockedCalls == 2, 'A fresh UTC-day plan window was not discovered');

  var calls = 0;
  var time = now;
  final gate = Completer<void>();
  final cache = FixtureCache((day) async { calls++; await gate.future; return []; },
    clock: () => time, interval: Duration.zero, dailyLimit: 2);
  final first = cache.get('2026-10-02');
  final duplicate = cache.get('2026-10-02');
  gate.complete();
  await Future.wait([first, duplicate]);
  check(calls == 1, 'Concurrent same-date requests consumed two upstream calls');
  await cache.get('2026-10-02');
  check(calls == 1, 'Fresh cache was not reused');
  time = time.add(const Duration(minutes: 16));
  await cache.get('2026-10-02');
  check(calls == 2, 'Expired cache was not refreshed');
  try {
    await cache.get('2026-10-03');
    throw StateError('Daily request cap was bypassed');
  } on ApiFailure catch (error) { check(error.code == 'daily_limit', 'Wrong quota error'); }
  time = DateTime.utc(2026, 10, 3, 1);
  await cache.get('2026-10-03');
  check(calls == 3, 'UTC day rollover did not reset quota');
  print('Backend window, null-score, deduplication, cache and quota checks passed.');
}
