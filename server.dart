import 'dart:async';
import 'dart:convert';
import 'dart:io';

// Local mode binds only to loopback. Cloud mode requires explicit configuration
// and a client access token. The football API key stays on the server.
typedef Json = Map<String, dynamic>;
Json asMap(dynamic value) => value is Map ? Map<String, dynamic>.from(value) : {};

class ApiFailure implements Exception {
  const ApiFailure(this.code, this.status, {this.details = const {}});
  final String code;
  final int status;
  final Json details;
}

class ServerConfig {
  const ServerConfig({this.public = false, this.port = 8787,
    this.publicHost = '', this.clientToken = ''});
  final bool public;
  final int port;
  final String publicHost;
  final String clientToken;
  InternetAddress get address => public
    ? InternetAddress.anyIPv4 : InternetAddress.loopbackIPv4;

  factory ServerConfig.fromEnvironment(Map<String, String> env) {
    final renderHost = env['RENDER_EXTERNAL_HOSTNAME']?.trim() ?? '';
    final public = env['MATCHLY_PUBLIC_SERVER'] == 'true' || renderHost.isNotEmpty;
    if (!public) return const ServerConfig();
    final host = (env['MATCHLY_PUBLIC_HOST'] ?? renderHost).trim().toLowerCase();
    final token = env['MATCHLY_CLIENT_TOKEN']?.trim() ?? '';
    final port = int.tryParse(env['PORT'] ?? '10000');
    if (host.isEmpty || !RegExp(r'^[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?$').hasMatch(host) ||
        port == null || port < 1024 || port > 65535 ||
        !RegExp(r'^[A-Za-z0-9_+/=\-]{32,128}$').hasMatch(token)) {
      throw const ApiFailure('invalid_cloud_config', 500);
    }
    return ServerConfig(public: true, port: port, publicHost: host, clientToken: token);
  }

  bool acceptsHost(String? header) {
    final host = Uri.tryParse('http://${header ?? ''}')?.host;
    return host == 'localhost' || host == '127.0.0.1' ||
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
    if (hours < 22 || hours > 26 ||
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
    if (id == null || kickoff == null || kickoff.isBefore(window.start) ||
        !kickoff.isBefore(window.end)) continue;
    final league = asMap(row['league']);
    final teams = asMap(row['teams']);
    final home = asMap(teams['home']);
    final away = asMap(teams['away']);
    if (league['id'] == null || home['id'] == null || away['id'] == null) continue;
    final status = asMap(fixture['status']);
    final goals = asMap(row['goals']);
    fixtures['$id'] = {
      'id': '$id',
      'kickoff': kickoff.toIso8601String(),
      'status': '${status['short'] ?? 'UNKNOWN'}',
      'elapsed': status['elapsed'] is num ? status['elapsed'] : null,
      'home': {'id': '${home['id']}', 'name': '${home['name'] ?? 'Home'}'},
      'away': {'id': '${away['id']}', 'name': '${away['name'] ?? 'Away'}'},
      'league': {'id': '${league['id']}', 'name': '${league['name'] ?? 'Competition'}',
        'country': '${league['country'] ?? 'World'}'},
      'goals': {'home': goals['home'] is num ? goals['home'] : null,
        'away': goals['away'] is num ? goals['away'] : null},
    };
  }
  final result = fixtures.values.toList();
  result.sort((a, b) => (a['kickoff'] as String).compareTo(b['kickoff'] as String));
  return result;
}

class CachedDay {
  const CachedDay(this.rows, this.at);
  final List<dynamic> rows;
  final DateTime at;
}

// Shared UTC-day cache and in-flight deduplication protect the free quota.
class FixtureCache {
  FixtureCache(this.loader, {DateTime Function()? clock,
      this.interval = const Duration(seconds: 7), this.dailyLimit = 90})
      : clock = clock ?? DateTime.now;
  final Future<List<dynamic>> Function(String) loader;
  final DateTime Function() clock;
  final Duration interval;
  final int dailyLimit;
  final Map<String, CachedDay> _cache = {};
  final Map<String, Future<CachedDay>> _pending = {};
  Future<void> _queue = Future<void>.value();
  DateTime? _lastCall;
  String _quotaDay = '';
  int _calls = 0;
  Json? lastProviderFailure;
  Json? _providerCoverage;
  String _coverageUtcDay = '';
  Json? get providerCoverage => _coverageUtcDay ==
    clock().toUtc().toIso8601String().substring(0, 10) ? _providerCoverage : null;

  void recordProviderFailure(ApiFailure error, String day) {
    final today = clock().toUtc().toIso8601String().substring(0, 10);
    lastProviderFailure = {
      'code': error.code, 'requestedUtcDate': day,
      'recordedAt': clock().toUtc().toIso8601String(), ...error.details,
    };
    final from = error.details['allowedFrom'];
    final to = error.details['allowedTo'];
    if (error.code == 'provider_plan' && error.details['reason'] == 'date_scope' &&
        from is String && to is String && from.compareTo(to) <= 0) {
      _coverageUtcDay = today;
      _providerCoverage = {'from': from, 'to': to, 'checkedUtcDay': today};
    }
  }

  Future<CachedDay> get(String day) {
    final coverage = providerCoverage;
    if (coverage != null && (day.compareTo(coverage['from'] as String) < 0 ||
        day.compareTo(coverage['to'] as String) > 0)) {
      final error = ApiFailure('provider_plan', 502, details: {
        'reason': 'date_scope', 'allowedFrom': coverage['from'], 'allowedTo': coverage['to'],
      });
      recordProviderFailure(error, day);
      return Future<CachedDay>.error(error);
    }
    final cached = _cache[day];
    if (cached != null && clock().difference(cached.at) < const Duration(minutes: 15)) {
      return Future.value(cached);
    }
    final pending = _pending[day];
    if (pending != null) return pending;
    final completer = Completer<CachedDay>();
    _pending[day] = completer.future;
    _queue = _queue.then((_) async {
      try {
        final today = clock().toUtc().toIso8601String().substring(0, 10);
        if (_quotaDay != today) { _quotaDay = today; _calls = 0; }
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
          final oldest = _cache.keys.reduce((a, b) => _cache[a]!.at.isBefore(_cache[b]!.at) ? a : b);
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
  final reason = text.contains('season') ? 'season_scope'
    : text.contains('date') ? 'date_scope'
    : text.contains('expired') || text.contains('inactive') || text.contains('not subscribed')
      ? 'subscription_state' : 'plan_scope';
  final details = <String, dynamic>{'reason': reason};
  // Extract only labelled bounds, never arbitrary numbers or provider messages.
  final dates = RegExp(r'\b(?:from|between)\s+(20\d{2}-\d{2}-\d{2})\s+(?:to|and)\s+(20\d{2}-\d{2}-\d{2})\b')
    .firstMatch(text);
  bool validDate(String value) {
    final date = DateTime.tryParse(value);
    return date != null && date.toIso8601String().startsWith(value);
  }
  if (dates != null && validDate(dates[1]!) && validDate(dates[2]!)) {
    details['allowedFrom'] = dates[1]!;
    details['allowedTo'] = dates[2]!;
  } else if (reason == 'season_scope') {
    final years = RegExp(r'\b(?:from|between)\s+(20\d{2})\s+(?:to|and)\s+(20\d{2})\b').firstMatch(text);
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
    ? rawText.replaceAll(secret.toLowerCase(), '[hidden]') : rawText;
  if (RegExp(r'\b(token|key|authentication|authorization)\b').hasMatch(fields) ||
      RegExp(r'(invalid|missing|incorrect|expired).{0,30}(api.?key|token)').hasMatch(text) ||
      RegExp(r'(api.?key|token).{0,30}(invalid|missing|incorrect|expired)').hasMatch(text)) {
    return const ApiFailure('provider_auth', 502);
  }
  if (RegExp(r'\b(plan|subscription)\b').hasMatch(fields)) {
    return ApiFailure('provider_plan', 502, details: planDetails(text));
  }
  if (fields.contains('rate') || fields.contains('request') || fields.contains('quota') ||
      text.contains('rate limit') || text.contains('quota') ||
      text.contains('request limit') || text.contains('requests limit')) {
    return const ApiFailure('provider_limit', 429);
  }
  if (text.contains('free plan') || text.contains('subscription') ||
      text.contains('not subscribed')) {
    return ApiFailure('provider_plan', 502, details: planDetails(text));
  }
  if (RegExp(r'\b(date|timezone|season|league|parameter)\b').hasMatch(fields)) {
    return const ApiFailure('provider_parameters', 502);
  }
  return const ApiFailure('provider_access', 502);
}

class FootballProvider {
  FootballProvider(this.key);
  final String key;

  Future<List<dynamic>> fetch(String day) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 12);
    final deadline = Timer(const Duration(seconds: 25), () => client.close(force: true));
    try {
      final uri = Uri.https('v3.football.api-sports.io', '/fixtures',
          {'date': day, 'timezone': 'UTC'});
      final request = await client.getUrl(uri).timeout(const Duration(seconds: 12));
      request.followRedirects = false;
      request.headers.set('x-apisports-key', key);
      final response = await request.close().timeout(const Duration(seconds: 15));
      if (response.statusCode == 429) throw const ApiFailure('provider_limit', 429);
      if (response.statusCode == 401) throw const ApiFailure('provider_auth', 502);
      if (response.statusCode == 403) throw const ApiFailure('provider_access', 502);
      if (response.statusCode != 200) throw const ApiFailure('provider_unavailable', 502);
      final body = await response.transform(utf8.decoder).join().timeout(const Duration(seconds: 15));
      final data = asMap(jsonDecode(body));
      final errors = data['errors'];
      if ((errors is Map && errors.isNotEmpty) || (errors is List && errors.isNotEmpty)) {
        throw classifyProviderError(errors, secret: key);
      }
      if (data['response'] is! List) throw const ApiFailure('invalid_provider_data', 502);
      return data['response'] as List<dynamic>;
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
}

String readKey() {
  final fromEnv = Platform.environment['MATCHLY_FOOTBALL_KEY']?.trim() ?? '';
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

Future<void> handle(HttpRequest request, FixtureCache cache,
    {ServerConfig config = const ServerConfig()}) async {
  try {
    if (!config.acceptsHost(request.headers.value('host'))) {
      await reply(request, 403, {'error': config.public ? 'host_not_allowed' : 'local_access_only'}); return;
    }
    final origin = request.headers.value('origin');
    if (origin != null) {
      final parsed = Uri.tryParse(origin);
      if (parsed == null || parsed.scheme != 'http' ||
          (parsed.host != 'localhost' && parsed.host != '127.0.0.1')) {
        await reply(request, 403, {'error': 'origin_not_allowed'}); return;
      }
      request.response.headers.set('access-control-allow-origin', origin);
      request.response.headers.set('vary', 'Origin');
      request.response.headers.set('access-control-allow-methods', 'GET, OPTIONS');
      request.response.headers.set('access-control-allow-headers', 'content-type, authorization');
      request.response.headers.set('access-control-allow-private-network', 'true');
    }
    if (request.method == 'OPTIONS') {
      request.response.statusCode = 204;
      await request.response.close(); return;
    }
    if (request.method != 'GET') {
      await reply(request, 405, {'error': 'method_not_allowed'}); return;
    }
    if (request.uri.path == '/health') {
      final data = <String, dynamic>{'status': 'ok', 'serverVersion': '0.6.0'};
      if (config.authorized(request.headers.value('authorization'))) {
        data.addAll({'source': 'api-football',
          'lastProviderError': cache.lastProviderFailure, 'coverage': cache.providerCoverage});
      }
      await reply(request, 200, data); return;
    }
    if (request.uri.path != '/fixtures') {
      await reply(request, 404, {'error': 'not_found'}); return;
    }
    if (!config.authorized(request.headers.value('authorization'))) {
      await reply(request, 401, {'error': 'client_auth'}); return;
    }
    final window = Window.parse(request.uri.queryParameters, DateTime.now());
    final rows = <dynamic>[];
    DateTime? oldest;
    for (final day in window.utcDays) {
      final snapshot = await cache.get(day);
      rows.addAll(snapshot.rows);
      if (oldest == null || snapshot.at.isBefore(oldest)) oldest = snapshot.at;
    }
    await reply(request, 200, {
      'fixtures': normalize(rows, window),
      'fetchedAt': oldest!.toUtc().toIso8601String(),
      'source': 'api-football',
      'cacheMinutes': 15, 'coverage': cache.providerCoverage,
    });
  } on ApiFailure catch (error) {
    await reply(request, error.status, {'error': error.code, 'coverage': cache.providerCoverage});
  } catch (_) {
    await reply(request, 500, {'error': 'server_error'});
  }
}

Future<void> main() async {
  ServerConfig config;
  try {
    config = ServerConfig.fromEnvironment(Platform.environment);
  } catch (_) {
    stderr.writeln('Bulut ayarlari eksik. MATCHLY_CLIENT_TOKEN, sunucu adi ve PORT ayarlarini kontrol edin.');
    exitCode = 1; return;
  }
  String key;
  try {
    if (config.public && (Platform.environment['MATCHLY_FOOTBALL_KEY']?.trim() ?? '').isEmpty) {
      stderr.writeln('MATCHLY_FOOTBALL_KEY sunucu ortam ayarina eklenmeli.');
      exitCode = 1; return;
    }
    key = readKey();
    if (key.isEmpty) { stderr.writeln('API anahtari bos. Sunucuyu yeniden baslatin.'); exitCode = 1; return; }
  } catch (_) {
    stderr.writeln('Gizli giris acilamadi. VS Code New Terminal ile deneyin.');
    exitCode = 1; return;
  }
  final cache = FixtureCache(FootballProvider(key).fetch);
  HttpServer server;
  try {
    server = await HttpServer.bind(config.address, config.port);
  } catch (_) {
    stderr.writeln('Sunucu portu acilamadi. Calisan sunucuyu ve port ayarini kontrol edin.');
    exitCode = 1; return;
  }
  if (config.public) {
    stdout.writeln('MATCHLY bulut sunucusu hazir. Port: ${config.port}');
  } else {
    stdout.writeln('MATCHLY sunucusu hazir: http://127.0.0.1:8787');
    stdout.writeln('Bu terminal acik kalsin. Durdurmak icin Ctrl+C.');
  }
  await for (final request in server) {
    unawaited(handle(request, cache, config: config));
  }
}
