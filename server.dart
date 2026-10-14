import 'dart:async';
import 'dart:convert';
import 'dart:io';

// Local mode binds only to loopback. Cloud mode requires explicit configuration
// and a client access token. The football API key stays on the server.
typedef Json = Map<String, dynamic>;
Json asMap(dynamic value) =>
    value is Map ? Map<String, dynamic>.from(value) : {};

class ApiFailure implements Exception {
  const ApiFailure(this.code, this.status, {this.details = const {}});
  final String code;
  final int status;
  final Json details;
}

class ServerConfig {
  const ServerConfig({
    this.public = false,
    this.port = 8787,
    this.publicHost = '',
    this.clientToken = '',
  });
  final bool public;
  final int port;
  final String publicHost;
  final String clientToken;
  InternetAddress get address =>
      public ? InternetAddress.anyIPv4 : InternetAddress.loopbackIPv4;

  factory ServerConfig.fromEnvironment(Map<String, String> env) {
    final renderHost = env['RENDER_EXTERNAL_HOSTNAME']?.trim() ?? '';
    final public =
        env['MATCHLY_PUBLIC_SERVER'] == 'true' || renderHost.isNotEmpty;
    if (!public) return const ServerConfig();
    final host = (env['MATCHLY_PUBLIC_HOST'] ?? renderHost)
        .trim()
        .toLowerCase();
    final token = env['MATCHLY_CLIENT_TOKEN']?.trim() ?? '';
    final port = int.tryParse(env['PORT'] ?? '10000');
    if (host.isEmpty ||
        !RegExp(r'^[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?$').hasMatch(host) ||
        port == null ||
        port < 1024 ||
        port > 65535 ||
        !RegExp(r'^[A-Za-z0-9_+/=\-]{32,128}$').hasMatch(token)) {
      throw const ApiFailure('invalid_cloud_config', 500);
    }
    return ServerConfig(
      public: true,
      port: port,
      publicHost: host,
      clientToken: token,
    );
  }

  bool acceptsHost(String? header) {
    final host = Uri.tryParse('http://${header ?? ''}')?.host;
    return host == 'localhost' ||
        host == '127.0.0.1' ||
        (public && host == publicHost);
  }

  bool authorized(String? header) {
    if (!public) return true;
    if (clientToken.isEmpty) return false;
    final expected = 'Bearer $clientToken';
    if (header == null || header.length != expected.length) return false;
    var difference = 0;
    for (var i = 0; i < expected.length; i++) {
      difference |= expected.codeUnitAt(i) ^ header.codeUnitAt(i);
    }
    return difference == 0;
  }
}

class Window {
  const Window(this.start, this.end);
  final DateTime start;
  final DateTime end;

  factory Window.parse(Map<String, String> params, DateTime now) {
    final start = DateTime.tryParse(params['start'] ?? '');
    final end = DateTime.tryParse(params['end'] ?? '');
    if (start == null || end == null || !start.isUtc || !end.isUtc) {
      throw const ApiFailure('invalid_window', 400);
    }
    final hours = end.difference(start).inMinutes / 60;
    if (hours < 22 ||
        hours > 26 ||
        start.isBefore(now.toUtc().subtract(const Duration(days: 2))) ||
        end.isAfter(now.toUtc().add(const Duration(days: 16)))) {
      throw const ApiFailure('invalid_window', 400);
    }
    return Window(start, end);
  }

  List<String> get utcDays {
    final result = <String>[];
    var day = DateTime.utc(start.year, start.month, start.day);
    while (day.isBefore(end)) {
      result.add(day.toIso8601String().substring(0, 10));
      day = day.add(const Duration(days: 1));
    }
    return result;
  }
}

List<Json> normalize(List<dynamic> rows, Window window) {
  final fixtures = <String, Json>{};
  for (final raw in rows) {
    final row = asMap(raw);
    final fixture = asMap(row['fixture']);
    final kickoff = DateTime.tryParse('${fixture['date'] ?? ''}')?.toUtc();
    final id = fixture['id'];
    if (id == null ||
        kickoff == null ||
        kickoff.isBefore(window.start) ||
        !kickoff.isBefore(window.end))
      continue;
    final league = asMap(row['league']);
    final teams = asMap(row['teams']);
    final home = asMap(teams['home']);
    final away = asMap(teams['away']);
    if (league['id'] == null || home['id'] == null || away['id'] == null)
      continue;
    final status = asMap(fixture['status']);
    final goals = asMap(row['goals']);
    fixtures['$id'] = {
      'id': '$id',
      'sport': row['sport'] == 'basketball' ? 'basketball' : 'football',
      'kickoff': kickoff.toIso8601String(),
      'status': '${status['short'] ?? 'UNKNOWN'}',
      'elapsed': status['elapsed'] is num ? status['elapsed'] : null,
      'home': {
        'id': '${home['id']}',
        'name': '${home['name'] ?? 'Home'}',
        'logo': home['logo'],
      },
      'away': {
        'id': '${away['id']}',
        'name': '${away['name'] ?? 'Away'}',
        'logo': away['logo'],
      },
      'league': {
        'id': '${league['id']}',
        'name': '${league['name'] ?? 'Competition'}',
        'country': '${league['country'] ?? 'World'}',
      },
      'goals': {
        'home': goals['home'] is num ? goals['home'] : null,
        'away': goals['away'] is num ? goals['away'] : null,
      },
    };
  }
  final result = fixtures.values.toList();
  result.sort(
    (a, b) => (a['kickoff'] as String).compareTo(b['kickoff'] as String),
  );
  return result;
}

class CachedDay {
  const CachedDay(this.rows, this.at);
  final List<dynamic> rows;
  final DateTime at;
}

const liveStatuses = {
  '1H',
  'HT',
  '2H',
  'ET',
  'BT',
  'P',
  'LIVE',
  'Q1',
  'Q2',
  'Q3',
  'Q4',
  'OT',
};

// Shared UTC-day cache and in-flight deduplication protect the free quota.
class FixtureCache {
  FixtureCache(
    this.loader, {
    DateTime Function()? clock,
    this.interval = const Duration(seconds: 7),
    this.dailyLimit = 900,
    this.fixedCacheMinutes,
  }) : clock = clock ?? DateTime.now;
  final Future<List<dynamic>> Function(String) loader;
  final DateTime Function() clock;
  final Duration interval;
  final int dailyLimit;
  final int? fixedCacheMinutes;
  final Map<String, CachedDay> _cache = {};
  final Map<String, Future<CachedDay>> _pending = {};
  Future<void> _queue = Future<void>.value();
  DateTime? _lastCall;
  String _quotaDay = '';
  int _calls = 0;
  Json? lastProviderFailure;
  Json? _providerCoverage;
  String _coverageUtcDay = '';
  Json? get providerCoverage =>
      _coverageUtcDay == clock().toUtc().toIso8601String().substring(0, 10)
      ? _providerCoverage
      : null;

  void recordProviderFailure(ApiFailure error, String day) {
    final today = clock().toUtc().toIso8601String().substring(0, 10);
    lastProviderFailure = {
      'code': error.code,
      'requestedUtcDate': day,
      'recordedAt': clock().toUtc().toIso8601String(),
      ...error.details,
    };
    final from = error.details['allowedFrom'];
    final to = error.details['allowedTo'];
    if (error.code == 'provider_plan' &&
        error.details['reason'] == 'date_scope' &&
        from is String &&
        to is String &&
        from.compareTo(to) <= 0) {
      _coverageUtcDay = today;
      _providerCoverage = {'from': from, 'to': to, 'checkedUtcDay': today};
    }
  }

  int cacheMinutesFor(String day, {bool live = false}) {
    if (fixedCacheMinutes != null) return fixedCacheMinutes!;
    if (!live) return 15;
    final now = clock().toUtc();
    final today = DateTime.utc(now.year, now.month, now.day);
    if (day == today.toIso8601String().substring(0, 10)) return 5;
    // A match can continue across UTC midnight. Do not repeatedly refresh
    // older completed/empty dates simply because Live also loads yesterday.
    if (day !=
        today
            .subtract(const Duration(days: 1))
            .toIso8601String()
            .substring(0, 10))
      return 15;
    for (final raw in _cache[day]?.rows ?? const []) {
      final fixture = asMap(asMap(raw)['fixture']);
      final status = asMap(fixture['status'])['short'];
      if (liveStatuses.contains(status)) return 5;
      final kickoff = DateTime.tryParse('${fixture['date']}')?.toUtc();
      if (status == 'NS' &&
          kickoff != null &&
          !kickoff.isAfter(now) &&
          now.difference(kickoff) <= const Duration(hours: 4))
        return 5;
    }
    return 15;
  }

  Future<CachedDay> get(String day, {bool live = false}) {
    final coverage = providerCoverage;
    if (coverage != null &&
        (day.compareTo(coverage['from'] as String) < 0 ||
            day.compareTo(coverage['to'] as String) > 0)) {
      final error = ApiFailure(
        'provider_plan',
        502,
        details: {
          'reason': 'date_scope',
          'allowedFrom': coverage['from'],
          'allowedTo': coverage['to'],
        },
      );
      recordProviderFailure(error, day);
      return Future<CachedDay>.error(error);
    }
    final cached = _cache[day];
    if (cached != null &&
        clock().difference(cached.at) <
            Duration(minutes: cacheMinutesFor(day, live: live))) {
      return Future.value(cached);
    }
    final pending = _pending[day];
    if (pending != null) return pending;
    final completer = Completer<CachedDay>();
    _pending[day] = completer.future;
    _queue = _queue.then((_) async {
      try {
        final today = clock().toUtc().toIso8601String().substring(0, 10);
        if (_quotaDay != today) {
          _quotaDay = today;
          _calls = 0;
        }
        if (_calls >= dailyLimit) throw const ApiFailure('daily_limit', 429);
        if (_lastCall != null) {
          final delay = interval - clock().difference(_lastCall!);
          if (delay > Duration.zero) await Future<void>.delayed(delay);
        }
        _lastCall = clock();
        _calls++;
        final value = CachedDay(await loader(day), clock());
        _cache[day] = value;
        // Retain enough UTC dates for the loaded digest horizon.
        if (_cache.length > 16) {
          final oldest = _cache.keys.reduce(
            (a, b) => _cache[a]!.at.isBefore(_cache[b]!.at) ? a : b,
          );
          _cache.remove(oldest);
        }
        completer.complete(value);
      } catch (error, stack) {
        if (error is ApiFailure && error.code.startsWith('provider_')) {
          recordProviderFailure(error, day);
        }
        completer.completeError(error, stack);
      } finally {
        _pending.remove(day);
      }
    });
    return completer.future;
  }
}

// Inspect errors only in memory. Return fixed categories; never forward messages,
// request headers, or credentials from a provider response to the client or logs.
Json planDetails(String text) {
  final reason = text.contains('season')
      ? 'season_scope'
      : text.contains('date')
      ? 'date_scope'
      : text.contains('expired') ||
            text.contains('inactive') ||
            text.contains('not subscribed')
      ? 'subscription_state'
      : 'plan_scope';
  final details = <String, dynamic>{'reason': reason};
  // Extract only labelled bounds, never arbitrary numbers or provider messages.
  final dates = RegExp(
    r'\b(?:from|between)\s+(20\d{2}-\d{2}-\d{2})\s+(?:to|and)\s+(20\d{2}-\d{2}-\d{2})\b',
  ).firstMatch(text);
  bool validDate(String value) {
    final date = DateTime.tryParse(value);
    return date != null && date.toIso8601String().startsWith(value);
  }

  if (dates != null && validDate(dates[1]!) && validDate(dates[2]!)) {
    details['allowedFrom'] = dates[1]!;
    details['allowedTo'] = dates[2]!;
  } else if (reason == 'season_scope') {
    final years = RegExp(
      r'\b(?:from|between)\s+(20\d{2})\s+(?:to|and)\s+(20\d{2})\b',
    ).firstMatch(text);
    if (years != null) {
      details['allowedSeasonFrom'] = int.parse(years[1]!);
      details['allowedSeasonTo'] = int.parse(years[2]!);
    }
  }
  return details;
}

ApiFailure classifyProviderError(dynamic errors, {String? secret}) {
  final fields = errors is Map ? errors.keys.join(' ').toLowerCase() : '';
  final rawText = jsonEncode(errors).toLowerCase();
  final text = secret != null && secret.isNotEmpty
      ? rawText.replaceAll(secret.toLowerCase(), '[hidden]')
      : rawText;
  if (RegExp(r'\b(token|key|authentication|authorization)\b')
          .hasMatch(fields) ||
      RegExp(r'(invalid|missing|incorrect|expired).{0,30}(api.?key|token)')
          .hasMatch(text) ||
      RegExp(r'(api.?key|token).{0,30}(invalid|missing|incorrect|expired)')
          .hasMatch(text)) {
    return const ApiFailure('provider_auth', 502);
  }
  if (RegExp(r'\b(plan|subscription)\b').hasMatch(fields)) {
    return ApiFailure('provider_plan', 502, details: planDetails(text));
  }
  if (fields.contains('rate') ||
      fields.contains('request') ||
      fields.contains('quota') ||
      text.contains('rate limit') ||
      text.contains('quota') ||
      text.contains('request limit') ||
      text.contains('requests limit')) {
    return const ApiFailure('provider_limit', 429);
  }
  if (text.contains('free plan') ||
      text.contains('subscription') ||
      text.contains('not subscribed')) {
    return ApiFailure('provider_plan', 502, details: planDetails(text));
  }
  if (RegExp(r'\b(date|timezone|season|league|parameter)\b').hasMatch(fields)) {
    return const ApiFailure('provider_parameters', 502);
  }
  return const ApiFailure('provider_access', 502);
}

const superLigId = 'cmr77dw0q00eprx06rqew3m48';

// Only strip known phase suffixes from the three supported UEFA cups.
// Keep provider IDs unchanged so saved follows and reminders still match.
String? europeanCupName(String raw) {
  final parts = raw.trim().toLowerCase().split(RegExp(r'\s+[-–—]\s+'));
  const names = {
    'uefa champions league': 'UEFA Champions League',
    'uefa europa league': 'UEFA Europa League',
    'uefa conference league': 'UEFA Conference League',
    'uefa europa conference league': 'UEFA Conference League',
  };
  final name = names[parts.first];
  if (name == null) return null;
  if (parts.length == 1) return name;
  if (parts.length != 2) return null;
  final stage = parts[1].trim();
  if (RegExp(
    r'^(league phase|group stage|group phase|qualification|qualifying|qualifiers|play-offs|playoffs|knockout phase play-offs|round of (16|32)|1/(8|16)-finals|quarter-finals|semi-finals|final|finals|[1-4](st|nd|rd|th) qualifying round)$',
  ).hasMatch(stage))
    return name;
  return null;
}

// Pair domestic league names with countries to exclude identically named
// competitions elsewhere. Preserve provider IDs for follows and deduplication.
bool supportedLeague(Json row) {
  if (row['leagueId'] == superLigId) return true;
  final league = asMap(row['league']);
  final name = '${row['leagueName'] ?? league['name'] ?? ''}'
      .trim()
      .toLowerCase();
  final country = '${row['countryName'] ?? ''}'.trim().toLowerCase();
  const domestic = <String, Set<String>>{
    'turkey': {'süper lig', 'super lig', '1. lig', 'tff 1. lig'},
    'england': {'premier league'},
    'spain': {'la liga', 'laliga'},
    'germany': {'bundesliga'},
    'italy': {'serie a'},
    'france': {'ligue 1'},
  };
  if (domestic[country]?.contains(name) ?? false) return true;
  return europeanCupName(name) != null;
}

// Convert provider rows into the existing client contract. Unknown scores stay
// null; matchLive is deliberately ignored because it can remain set after FT.
Json goalRow(Json row) {
  final statuses = <String, String>{
    'SCHEDULED': 'NS',
    'NOT_STARTED': 'NS',
    'FINISHED': 'FT',
    'POSTPONED': 'PST',
    'CANCELLED': 'CANC',
    'CANCELED': 'CANC',
    'ABANDONED': 'ABD',
    'SUSPENDED': 'SUSP',
    'LIVE': 'LIVE',
    'IN_PLAY': 'LIVE',
    'FIRST_HALF': '1H',
    'HALF_TIME': 'HT',
    'HALFTIME': 'HT',
    'SECOND_HALF': '2H',
    'EXTRA_TIME': 'ET',
    'PENALTIES': 'P',
    'AFTER_EXTRA_TIME': 'AET',
    'AFTER_PENALTIES': 'PEN',
  };
  final state = '${row['matchStatus'] ?? ''}'.toUpperCase();
  final period = '${row['matchPeriod'] ?? ''}'.toUpperCase();
  final terminal = {
    'FINISHED',
    'POSTPONED',
    'CANCELLED',
    'CANCELED',
    'ABANDONED',
    'SUSPENDED',
    'AFTER_EXTRA_TIME',
    'AFTER_PENALTIES',
  };
  final status = terminal.contains(state)
      ? statuses[state]!
      : statuses[period] ?? statuses[state] ?? 'UNKNOWN';
  int? number(dynamic value) => int.tryParse('$value');
  final home = asMap(row['homeTeam']);
  final away = asMap(row['awayTeam']);
  return {
    'fixture': {
      'id': row['id'],
      'date': row['kickoffUtc'],
      'status': {'short': status, 'elapsed': number(row['matchElapsed'])},
    },
    'league': {
      'id': row['leagueId'] ?? asMap(row['league'])['id'],
      'name':
          europeanCupName(
            '${row['leagueName'] ?? asMap(row['league'])['name'] ?? ''}',
          ) ??
          row['leagueName'] ??
          asMap(row['league'])['name'] ??
          'Competition',
      'country': row['countryName'] ?? 'World',
    },
    'teams': {
      'home': {
        'id': row['homeTeamId'] ?? home['id'],
        'name': home['name'] ?? row['homeTeamName'],
        'logo': row['teamHomeBadge'] ?? home['badge'],
      },
      'away': {
        'id': row['awayTeamId'] ?? away['id'],
        'name': away['name'] ?? row['awayTeamName'],
        'logo': row['teamAwayBadge'] ?? away['badge'],
      },
    },
    'goals': {
      'home': number(row['homeTeamScore']),
      'away': number(row['awayTeamScore']),
    },
  };
}

class FootballProvider {
  FootballProvider(
    this.key, {
    this.dailyLimit = 900,
    this.pageLoader,
    DateTime Function()? clock,
  }) : clock = clock ?? DateTime.now;
  final String key;
  final int dailyLimit;
  final DateTime Function() clock;
  final Future<Json> Function(String day, int offset)? pageLoader;
  String _quotaDay = '';
  int _calls = 0;

  Future<Json> _page(String day, int offset, {String? fixtureId}) async {
    final today = clock().toUtc().toIso8601String().substring(0, 10);
    if (_quotaDay != today) {
      _quotaDay = today;
      _calls = 0;
    }
    if (_calls >= dailyLimit) throw const ApiFailure('daily_limit', 429);
    _calls++;
    if (pageLoader != null) return pageLoader!(day, offset);
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 12);
    final deadline = Timer(
      const Duration(seconds: 25),
      () => client.close(force: true),
    );
    try {
      final uri = Uri.https(
        'api.goal-api.com',
        fixtureId == null
            ? '/v1/fixtures/date/$day'
            : '/v1/fixtures/$fixtureId/events',
        fixtureId == null ? {'limit': '100', 'offset': '$offset'} : null,
      );
      final request = await client
          .getUrl(uri)
          .timeout(const Duration(seconds: 12));
      request.followRedirects = false;
      request.headers.set('authorization', 'Bearer $key');
      final response = await request.close().timeout(
        const Duration(seconds: 15),
      );
      if (response.statusCode == 429)
        throw const ApiFailure('provider_limit', 429);
      if (response.statusCode == 401)
        throw const ApiFailure('provider_auth', 502);
      if (response.statusCode == 403)
        throw const ApiFailure('provider_access', 502);
      if (response.statusCode != 200)
        throw const ApiFailure('provider_unavailable', 502);
      final body = await response
          .transform(utf8.decoder)
          .join()
          .timeout(const Duration(seconds: 15));
      return asMap(jsonDecode(body));
    } on ApiFailure {
      rethrow;
    } on TimeoutException {
      throw const ApiFailure('provider_timeout', 504);
    } catch (_) {
      throw const ApiFailure('provider_unavailable', 502);
    } finally {
      deadline.cancel();
      client.close(force: true);
    }
  }

  Future<Json> events(String id) async {
    final data = await _page('', 0, fixtureId: id);
    if (data['success'] != true ||
        data['data'] is! List ||
        data['fixtureId'] != id) {
      throw const ApiFailure('invalid_provider_data', 502);
    }
    final goals = <Json>[];
    final seen = <String>{};
    for (final item in data['data'] as List) {
      final row = asMap(item);
      if (row['type'] != 'GOAL') continue;
      final eventId = '${row['id'] ?? ''}';
      if (eventId.isNotEmpty && !seen.add(eventId)) continue;
      goals.add({
        for (final key in [
          'id',
          'time',
          'homeScorer',
          'awayScorer',
          'homeAssist',
          'awayAssist',
          'score',
          'info',
        ])
          key: row[key],
      });
    }
    return {'fixtureId': id, 'goals': goals};
  }

  Future<List<dynamic>> fetch(String day) async {
    final rows = <dynamic>[];
    var offset = 0;
    // Fail closed on incomplete pagination: never cache a partial day as empty.
    for (var page = 0; page < 100; page++) {
      final data = await _page(day, offset);
      final pagination = asMap(data['pagination']);
      if (data['success'] != true ||
          data['data'] is! List ||
          pagination['hasMore'] is! bool ||
          pagination['offset'] != offset) {
        throw const ApiFailure('invalid_provider_data', 502);
      }
      final batch = data['data'] as List;
      for (final raw in batch) {
        final row = asMap(raw);
        if (supportedLeague(row)) rows.add(goalRow(row));
      }
      if (pagination['hasMore'] == false) return rows;
      final limit = pagination['limit'];
      if (batch.isEmpty || limit is! int || limit <= 0 || limit > 100) {
        throw const ApiFailure('invalid_provider_data', 502);
      }
      offset += limit;
    }
    throw const ApiFailure('invalid_provider_data', 502);
  }
}

// Highlightly identities are namespaced to avoid collisions with football.
const basketballLeagues = <int, String>{
  10996: 'NBA',
  102904: 'EuroLeague',
  89288: 'Basketbol Süper Ligi',
};

Json basketballRow(Json row) {
  final league = asMap(row['league']);
  final home = asMap(row['homeTeam']);
  final away = asMap(row['awayTeam']);
  if (row['id'] == null ||
      home['id'] == null ||
      away['id'] == null ||
      DateTime.tryParse('${row['date']}') == null) {
    throw const ApiFailure('invalid_provider_data', 502);
  }
  const statuses = <String, String>{
    'Not started': 'NS',
    'To be announced': 'TBD',
    'First quarter': 'Q1',
    'Second quarter': 'Q2',
    'Third quarter': 'Q3',
    'Fourth quarter': 'Q4',
    'Over time': 'OT',
    'Break time': 'BT',
    'Half time': 'HT',
    'Finished': 'FT',
    'Finished after over time': 'AET',
    'Postponed': 'PST',
    'Cancelled': 'CANC',
    'Suspended': 'SUSP',
    'Awarded': 'AWD',
    'Abandoned': 'ABD',
  };
  final state = asMap(row['state']);
  final score = RegExp(r'^\s*(\d+)\s*-\s*(\d+)\s*$')
      .firstMatch('${asMap(state['score'])['current'] ?? ''}');
  Json team(Json value) => {
    'id': 'hl-basket-${value['id']}',
    'name': value['name'],
    'logo': value['logo'],
  };
  return {
    'sport': 'basketball',
    'fixture': {
      'id': 'hl-basket-${row['id']}',
      'date': row['date'],
      // Do not turn the provider's quarter clock into football elapsed minutes.
      'status': {
        'short': statuses[state['description']] ?? 'UNKNOWN',
        'elapsed': null,
      },
    },
    'league': {
      'id': 'hl-basket-${league['id']}',
      'name': basketballLeagues[league['id']],
      'country': asMap(row['country'])['name'] ?? 'World',
    },
    'teams': {'home': team(home), 'away': team(away)},
    'goals': {
      'home': score == null ? null : int.parse(score[1]!),
      'away': score == null ? null : int.parse(score[2]!),
    },
  };
}

class BasketballProvider {
  BasketballProvider(
    this.key, {
    this.dailyLimit = 90,
    this.pageLoader,
    DateTime Function()? clock,
  }) : clock = clock ?? DateTime.now;
  final String key;
  final int dailyLimit;
  final DateTime Function() clock;
  final Future<Json> Function(String day, int offset)? pageLoader;
  String _quotaDay = '';
  int _calls = 0;
  DateTime? _blockedUntil;

  Future<Json> _page(String day, int offset) async {
    final now = clock().toUtc();
    final today = now.toIso8601String().substring(0, 10);
    if (_quotaDay != today) {
      _quotaDay = today;
      _calls = 0;
    }
    if (_blockedUntil != null && now.isBefore(_blockedUntil!)) {
      throw const ApiFailure('provider_limit', 429);
    }
    if (_calls >= dailyLimit) throw const ApiFailure('daily_limit', 429);
    _calls++;
    if (pageLoader != null) return pageLoader!(day, offset);
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 12);
    final deadline = Timer(
      const Duration(seconds: 25),
      () => client.close(force: true),
    );
    try {
      final request = await client.getUrl(
        Uri.https('basketball.highlightly.net', '/matches', {
          'date': day,
          'timezone': 'Etc/UTC',
          'limit': '100',
          'offset': '$offset',
        }),
      );
      request.followRedirects = false;
      request.headers.set('x-rapidapi-key', key);
      final response = await request.close();
      final remaining = int.tryParse(
        response.headers.value('x-ratelimit-requests-remaining') ?? '',
      );
      if (response.statusCode == 429 || remaining == 0) {
        // Conservative backoff avoids hammering the daily quota after restarts.
        _blockedUntil = now.add(const Duration(hours: 24));
      }
      if (response.statusCode == 429)
        throw const ApiFailure('provider_limit', 429);
      if (response.statusCode == 401)
        throw const ApiFailure('provider_auth', 502);
      if (response.statusCode == 403)
        throw const ApiFailure('provider_access', 502);
      if (response.statusCode != 200)
        throw const ApiFailure('provider_unavailable', 502);
      return asMap(jsonDecode(await response.transform(utf8.decoder).join()));
    } on ApiFailure {
      rethrow;
    } catch (_) {
      throw const ApiFailure('provider_unavailable', 502);
    } finally {
      deadline.cancel();
      client.close(force: true);
    }
  }

  Future<List<dynamic>> fetch(String day) async {
    final rows = <dynamic>[];
    var offset = 0;
    for (var page = 0; page < 100; page++) {
      final data = await _page(day, offset);
      final pagination = asMap(data['pagination']);
      final total = pagination['totalCount'];
      if (data['data'] is! List ||
          total is! int ||
          total < 0 ||
          pagination['offset'] != offset) {
        throw const ApiFailure('invalid_provider_data', 502);
      }
      final planMessage = '${asMap(data['plan'])['message'] ?? ''}'
          .toLowerCase();
      if (planMessage.contains('hidden') ||
          planMessage.contains('restricted')) {
        throw const ApiFailure('provider_plan', 502);
      }
      final batch = data['data'] as List;
      for (final raw in batch) {
        final row = asMap(raw);
        if (basketballLeagues.containsKey(asMap(row['league'])['id'])) {
          rows.add(basketballRow(row));
        }
      }
      if (offset + batch.length >= total) return rows;
      final limit = pagination['limit'];
      if (limit is! int || limit <= 0 || limit > 100 || batch.length != limit) {
        throw const ApiFailure('invalid_provider_data', 502);
      }
      offset += limit;
    }
    throw const ApiFailure('invalid_provider_data', 502);
  }
}

String readKey() {
  final fromEnv = Platform.environment['MATCHLY_GOAL_KEY']?.trim() ?? '';
  if (fromEnv.isNotEmpty) return fromEnv;
  if (!stdin.hasTerminal) throw const ApiFailure('terminal_required', 500);
  final oldEcho = stdin.echoMode;
  try {
    stdin.echoMode = false;
    stdout.write('API anahtarini yapistir ve Enter\'a bas (gizli): ');
    return (stdin.readLineSync() ?? '').trim();
  } finally {
    stdin.echoMode = oldEcho;
    stdout.writeln();
  }
}

Future<void> reply(HttpRequest request, int status, Json data) async {
  try {
    request.response.statusCode = status;
    request.response.headers.contentType = ContentType.json;
    request.response.headers.set('cache-control', 'no-store');
    request.response.headers.set('x-content-type-options', 'nosniff');
    request.response.write(jsonEncode(data));
    await request.response.close();
  } on IOException {
    // A closed browser tab must not stop the local server.
  }
}

class GoalEventCache {
  GoalEventCache(this.loader, {DateTime Function()? clock})
    : clock = clock ?? DateTime.now;
  final Future<Json> Function(String) loader;
  final DateTime Function() clock;
  final _saved = <String, Json>{};
  final _pending = <String, Future<Json>>{};
  DateTime? _retryAfter;
  Future<Json> get(String id) {
    if (!RegExp(r'^[a-zA-Z0-9_-]{1,80}$').hasMatch(id))
      throw const ApiFailure('invalid_fixture', 400);
    final saved = _saved[id];
    if (saved != null &&
        clock().difference(DateTime.parse(saved['fetchedAt'] as String)) <
            const Duration(minutes: 5))
      return Future.value(saved);
    if (_pending.containsKey(id)) return _pending[id]!;
    if (_retryAfter != null && clock().isBefore(_retryAfter!))
      throw const ApiFailure('events_retry_later', 503);
    if (_pending.length >= 8) throw const ApiFailure('events_busy', 503);
    final future = _load(id);
    _pending[id] = future;
    return future;
  }

  Future<Json> _load(String id) async {
    try {
      final data = await loader(id);
      final result = {
        ...data,
        'fetchedAt': clock().toUtc().toIso8601String(),
        'cacheMinutes': 5,
      };
      _saved.remove(id);
      _saved[id] = result;
      while (_saved.length > 256) {
        _saved.remove(_saved.keys.first);
      }
      return result;
    } catch (_) {
      _retryAfter = clock().add(const Duration(minutes: 1));
      rethrow;
    } finally {
      _pending.remove(id);
    }
  }
}

Future<void> handle(
  HttpRequest request,
  FixtureCache cache, {
  ServerConfig config = const ServerConfig(),
  FixtureCache? basketballCache,
  GoalEventCache? goalEvents,
}) async {
  try {
    if (!config.acceptsHost(request.headers.value('host'))) {
      await reply(request, 403, {
        'error': config.public ? 'host_not_allowed' : 'local_access_only',
      });
      return;
    }
    final origin = request.headers.value('origin');
    if (origin != null) {
      final parsed = Uri.tryParse(origin);
      if (parsed == null ||
          parsed.scheme != 'http' ||
          (parsed.host != 'localhost' && parsed.host != '127.0.0.1')) {
        await reply(request, 403, {'error': 'origin_not_allowed'});
        return;
      }
      request.response.headers.set('access-control-allow-origin', origin);
      request.response.headers.set('vary', 'Origin');
      request.response.headers.set(
        'access-control-allow-methods',
        'GET, OPTIONS',
      );
      request.response.headers.set(
        'access-control-allow-headers',
        'content-type, authorization',
      );
      request.response.headers.set(
        'access-control-allow-private-network',
        'true',
      );
    }
    if (request.method == 'OPTIONS') {
      request.response.statusCode = 204;
      await request.response.close();
      return;
    }
    if (request.method != 'GET') {
      await reply(request, 405, {'error': 'method_not_allowed'});
      return;
    }
    if (request.uri.path == '/health') {
      final data = <String, dynamic>{'status': 'ok', 'serverVersion': '0.9.0'};
      if (config.authorized(request.headers.value('authorization'))) {
        data.addAll({
          'source': 'goal-api',
          'basketballConfigured': basketballCache != null,
          'lastProviderError': cache.lastProviderFailure,
          'coverage': cache.providerCoverage,
        });
      }
      await reply(request, 200, data);
      return;
    }
    final eventRoute = RegExp(r'^/fixtures/([a-zA-Z0-9_-]{1,80})/events$')
        .firstMatch(request.uri.path);
    if (eventRoute != null) {
      if (!config.authorized(request.headers.value('authorization'))) {
        await reply(request, 401, {'error': 'client_auth'});
        return;
      }
      if (goalEvents == null)
        throw const ApiFailure('events_not_configured', 503);
      await reply(request, 200, await goalEvents.get(eventRoute.group(1)!));
      return;
    }
    final basketball = request.uri.path == '/basketball/fixtures';
    if (request.uri.path != '/fixtures' && !basketball) {
      await reply(request, 404, {'error': 'not_found'});
      return;
    }
    if (!config.authorized(request.headers.value('authorization'))) {
      await reply(request, 401, {'error': 'client_auth'});
      return;
    }
    if (basketball) {
      if (basketballCache == null) {
        throw const ApiFailure('basketball_not_configured', 503);
      }
      cache = basketballCache;
    }
    final liveParam = request.uri.queryParameters['live'];
    if (liveParam != null && liveParam != '1')
      throw const ApiFailure('invalid_mode', 400);
    final live = liveParam == '1';
    final window = Window.parse(request.uri.queryParameters, DateTime.now());
    final rows = <dynamic>[];
    DateTime? oldest;
    DateTime? liveTime;
    DateTime? currentTime;
    final today = cache.clock().toUtc().toIso8601String().substring(0, 10);
    for (final day in window.utcDays) {
      final snapshot = await cache.get(day, live: live);
      rows.addAll(snapshot.rows);
      if (oldest == null || snapshot.at.isBefore(oldest)) oldest = snapshot.at;
      if (day == today) currentTime = snapshot.at;
      if (normalize(
            snapshot.rows,
            window,
          ).any((row) => liveStatuses.contains(row['status'])) &&
          (liveTime == null || snapshot.at.isBefore(liveTime)))
        liveTime = snapshot.at;
    }
    await reply(request, 200, {
      'fixtures': normalize(rows, window),
      'fetchedAt': oldest!.toUtc().toIso8601String(),
      'source': basketball ? 'highlightly' : 'goal-api',
      'cacheMinutes': basketball ? 120 : (live ? 5 : 15),
      'coverage': cache.providerCoverage,
      if (live)
        'liveFetchedAt': (liveTime ?? currentTime ?? oldest)
            .toUtc()
            .toIso8601String(),
    });
  } on ApiFailure catch (error) {
    await reply(request, error.status, {
      'error': error.code,
      'coverage': cache.providerCoverage,
    });
  } catch (_) {
    await reply(request, 500, {'error': 'server_error'});
  }
}

Future<void> main() async {
  ServerConfig config;
  try {
    config = ServerConfig.fromEnvironment(Platform.environment);
  } catch (_) {
    stderr.writeln(
      'Bulut ayarlari eksik. MATCHLY_CLIENT_TOKEN, sunucu adi ve PORT ayarlarini kontrol edin.',
    );
    exitCode = 1;
    return;
  }
  String key;
  try {
    if (config.public &&
        (Platform.environment['MATCHLY_GOAL_KEY']?.trim() ?? '').isEmpty) {
      stderr.writeln('MATCHLY_GOAL_KEY sunucu ortam ayarina eklenmeli.');
      exitCode = 1;
      return;
    }
    key = readKey();
    if (key.isEmpty) {
      stderr.writeln('API anahtari bos. Sunucuyu yeniden baslatin.');
      exitCode = 1;
      return;
    }
  } catch (_) {
    stderr.writeln('Gizli giris acilamadi. VS Code New Terminal ile deneyin.');
    exitCode = 1;
    return;
  }
  final footballProvider = FootballProvider(key);
  final cache = FixtureCache(footballProvider.fetch);
  final goalEvents = GoalEventCache(footballProvider.events);
  final basketballKey =
      Platform.environment['MATCHLY_HIGHLIGHTLY_KEY']?.trim() ?? '';
  final basketballCache = basketballKey.isEmpty
      ? null
      : FixtureCache(
          BasketballProvider(basketballKey).fetch,
          interval: const Duration(seconds: 1),
          dailyLimit: 90,
          fixedCacheMinutes: 120,
        );
  HttpServer server;
  try {
    server = await HttpServer.bind(config.address, config.port);
  } catch (_) {
    stderr.writeln(
      'Sunucu portu acilamadi. Calisan sunucuyu ve port ayarini kontrol edin.',
    );
    exitCode = 1;
    return;
  }
  if (config.public) {
    stdout.writeln('MATCHLY bulut sunucusu hazir. Port: ${config.port}');
  } else {
    stdout.writeln('MATCHLY sunucusu hazir: http://127.0.0.1:8787');
    stdout.writeln('Bu terminal acik kalsin. Durdurmak icin Ctrl+C.');
  }
  await for (final request in server) {
    unawaited(
      handle(
        request,
        cache,
        config: config,
        basketballCache: basketballCache,
        goalEvents: goalEvents,
      ),
    );
  }
}
