import 'dart:convert';
import 'dart:io';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/iptv_channel.dart';

class IptvService {
  static const _cacheKey = 'iptv_channels_cache_v1';
  static const _cacheTimeKey = 'iptv_channels_cache_time_v1';
  static const _cacheTtl = Duration(hours: 12);

  // Берём легальный публичный источник iptv-org. Полный index.m3u слишком жирный
  // для спутника, поэтому стартуем с русскоязычного плейлиста.
  static const _sources = [
    'https://iptv-org.github.io/iptv/languages/rus.m3u',
  ];

  static const categoryOrder = [
    'Все',
    'Избранное',
    'Кино',
    'Мультфильмы',
    'Спорт',
    'Новости',
    'Познавательное',
    'Музыка',
    'Развлекательные',
    'Региональные',
    'Разное',
  ];

  static Future<List<IptvChannel>> loadChannels(
      {bool forceRefresh = false}) async {
    final prefs = await SharedPreferences.getInstance();
    if (!forceRefresh) {
      final cached = _readCache(prefs);
      if (cached.isNotEmpty) return cached;
    }

    try {
      final out = <IptvChannel>[];
      for (final source in _sources) {
        final body = await _download(source);
        out.addAll(parseM3u(body, source: source));
      }
      final cleaned = _dedupe(out);
      if (cleaned.isNotEmpty) {
        await _saveCache(prefs, cleaned);
        return cleaned;
      }
    } catch (_) {
      final cached = _readCache(prefs, ignoreTtl: true);
      if (cached.isNotEmpty) return cached;
    }

    return fallbackChannels;
  }

  static List<String> categoriesFor(List<IptvChannel> channels) {
    final set =
        channels.map((e) => e.category).where((e) => e.isNotEmpty).toSet();
    final ordered = <String>[];
    for (final c in categoryOrder) {
      if (c == 'Избранное') continue;
      if (c == 'Все' || set.contains(c)) ordered.add(c);
    }
    final tail = set.where((c) => !ordered.contains(c)).toList()..sort();
    return [...ordered, ...tail];
  }

  static Future<String> _download(String url) async {
    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 25);
    client.badCertificateCallback = (_, __, ___) => true;
    try {
      final req = await client.getUrl(Uri.parse(url));
      req.headers.set(HttpHeaders.userAgentHeader, 'VakhtovikPlayer/0.2 IPTV');
      final resp = await req.close().timeout(const Duration(seconds: 35));
      if (resp.statusCode != 200) {
        throw Exception('IPTV HTTP ${resp.statusCode}');
      }
      return utf8.decoder.bind(resp).join();
    } finally {
      client.close(force: true);
    }
  }

  static List<IptvChannel> parseM3u(String body, {String source = ''}) {
    final lines = const LineSplitter().convert(body);
    final out = <IptvChannel>[];
    Map<String, String>? pendingAttrs;
    String pendingName = '';

    for (final rawLine in lines) {
      final line = rawLine.trim();
      if (line.isEmpty) continue;

      if (line.startsWith('#EXTINF')) {
        pendingAttrs = _parseAttrs(line);
        final comma = line.indexOf(',');
        pendingName = comma >= 0 ? line.substring(comma + 1).trim() : '';
        continue;
      }

      if (line.startsWith('#')) continue;
      if (!line.startsWith('http://') && !line.startsWith('https://')) continue;

      final attrs = pendingAttrs ?? const <String, String>{};
      final name = _firstNonEmpty([
        pendingName,
        attrs['tvg-name'] ?? '',
        attrs['tvg-id'] ?? '',
        Uri.tryParse(line)?.host ?? '',
      ]);
      final group = attrs['group-title'] ?? '';
      final category = normalizeCategory(group, name);
      out.add(IptvChannel(
        name: name,
        url: line,
        category: category,
        logo: attrs['tvg-logo'] ?? '',
        country: attrs['tvg-country'] ?? '',
        language: attrs['tvg-language'] ?? '',
        source: source,
      ));
      pendingAttrs = null;
      pendingName = '';
    }
    return _dedupe(out);
  }

  static Map<String, String> _parseAttrs(String line) {
    final attrs = <String, String>{};
    final re = RegExp(r'([\w-]+)="([^"]*)"');
    for (final m in re.allMatches(line)) {
      attrs[(m.group(1) ?? '').toLowerCase()] = m.group(2) ?? '';
    }
    return attrs;
  }

  static String normalizeCategory(String group, String name) {
    final s = '$group $name'.toLowerCase();
    if (_hasAny(
        s, ['news', 'новост', 'вести', 'rt ', 'мир 24', 'rbc', 'рбк'])) {
      return 'Новости';
    }
    if (_hasAny(s, ['sport', 'спорт', 'football', 'футбол', 'хоккей', 'mma'])) {
      return 'Спорт';
    }
    if (_hasAny(s, ['kids', 'детск', 'cartoon', 'мульт', 'disney', 'nick'])) {
      return 'Мультфильмы';
    }
    if (_hasAny(s, ['movie', 'cinema', 'film', 'кино', 'сериал'])) {
      return 'Кино';
    }
    if (_hasAny(s, ['music', 'музык', 'музыка', 'radio', 'радио'])) {
      return 'Музыка';
    }
    if (_hasAny(s, [
      'documentary',
      'science',
      'history',
      'travel',
      'docu',
      'познав',
      'история',
      'наука'
    ])) {
      return 'Познавательное';
    }
    if (_hasAny(s, ['regional', 'local', 'регион', 'город', 'област'])) {
      return 'Региональные';
    }
    if (_hasAny(s, ['entertainment', 'развлек', 'general', 'общий'])) {
      return 'Развлекательные';
    }
    return group.trim().isNotEmpty ? _humanGroup(group) : 'Разное';
  }

  static bool _hasAny(String value, List<String> needles) {
    for (final n in needles) {
      if (value.contains(n)) return true;
    }
    return false;
  }

  static String _humanGroup(String group) {
    final g = group.trim();
    if (g.isEmpty) return 'Разное';
    final low = g.toLowerCase();
    if (low == 'undefined' || low == 'none') return 'Разное';
    return g[0].toUpperCase() + (g.length > 1 ? g.substring(1) : '');
  }

  static String _firstNonEmpty(List<String> values) {
    for (final v in values) {
      final t = v.trim();
      if (t.isNotEmpty) return t;
    }
    return 'IPTV канал';
  }

  static List<IptvChannel> _dedupe(List<IptvChannel> channels) {
    final seen = <String>{};
    final out = <IptvChannel>[];
    for (final ch in channels) {
      final url = ch.url.trim();
      if (url.isEmpty || seen.contains(url)) continue;
      seen.add(url);
      out.add(ch);
    }
    out.sort((a, b) {
      final ca = categoryOrder.indexOf(a.category);
      final cb = categoryOrder.indexOf(b.category);
      final ai = ca < 0 ? 999 : ca;
      final bi = cb < 0 ? 999 : cb;
      if (ai != bi) return ai.compareTo(bi);
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return out;
  }

  static List<IptvChannel> _readCache(SharedPreferences prefs,
      {bool ignoreTtl = false}) {
    final raw = prefs.getString(_cacheKey);
    final time = prefs.getInt(_cacheTimeKey) ?? 0;
    if (raw == null || raw.isEmpty) return const [];
    if (!ignoreTtl) {
      final age = DateTime.now().millisecondsSinceEpoch - time;
      if (age > _cacheTtl.inMilliseconds) return const [];
    }
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      return list
          .whereType<Map<String, dynamic>>()
          .map(IptvChannel.fromJson)
          .where((e) => e.name.isNotEmpty && e.url.isNotEmpty)
          .toList();
    } catch (_) {
      return const [];
    }
  }

  static Future<void> _saveCache(
      SharedPreferences prefs, List<IptvChannel> channels) async {
    await prefs.setString(
        _cacheKey, jsonEncode(channels.map((e) => e.toJson()).toList()));
    await prefs.setInt(_cacheTimeKey, DateTime.now().millisecondsSinceEpoch);
  }

  static const fallbackChannels = [
    IptvChannel(
      name: 'NASA TV',
      url: 'https://ntv1.infomaniak.com/livecast/ik:ntv1/manifest.m3u8',
      category: 'Познавательное',
      country: 'US',
      language: 'English',
      source: 'fallback',
    ),
    IptvChannel(
      name: 'Akamai Test Live',
      url:
          'https://cph-p2p-msl.akamaized.net/hls/live/2000341/test/master.m3u8',
      category: 'Разное',
      source: 'fallback',
    ),
    IptvChannel(
      name: 'MUX Big Buck Bunny 360p',
      url: 'https://test-streams.mux.dev/bbb-360p.m3u8',
      category: 'Мультфильмы',
      source: 'fallback',
    ),
    IptvChannel(
      name: 'Apple BipBop Test',
      url:
          'https://devstreaming-cdn.apple.com/videos/streaming/examples/img_bipbop_adv_example_ts/master.m3u8',
      category: 'Кино',
      source: 'fallback',
    ),
  ];
}
