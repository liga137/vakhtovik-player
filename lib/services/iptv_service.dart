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
  // При недоступности используем встроенный список каналов (не требует интернета).
  static const _sources = <String, String>{
    'russia': 'https://sat-portal.com/upload/rus_22.05.2026.m3u8',
  };
  // Беларусь — только из встроенного fallback (надёжнее)

  static const categoryOrder = [
    'Все',
    'Избранное',
    'Общероссийские',
    'Кино',
    'Мультфильмы',
    'Спорт',
    'Новости',
    'Познавательные',
    'Музыкальные',
    'Украина',
    'Беларусь',
    'Türkiye',
    'Azerbaijan',
    'Israel',
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
      for (final entry in _sources.entries) {
        final body = await _download(entry.value);
        out.addAll(parseM3u(body, source: entry.value));
      }
      final cleaned = _dedupe(out);
      if (cleaned.isNotEmpty) { await _saveCache(prefs, cleaned); return cleaned; }
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
    client.findProxy = (uri) => 'PROXY 127.0.0.1:1080; DIRECT';
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
    // Общероссийские
    IptvChannel(
      name: 'Первый канал',
      url: 'http://bethoven.af-stream.com:8080/s/pyxm92zq/pervyj/video.m3u8',
      category: 'Общероссийские', country: 'Россия',
      logo:
          'https://af-play.com/storage/images/pack_logos/cdef747b13675ef8302fe8283b7de688.png',
      source: 'fallback',
    ),
    IptvChannel(
      name: 'Первый HD',
      url: 'http://bethoven.af-stream.com:8080/s/pyxm92zq/pervyj-hd/video.m3u8',
      category: 'Общероссийские',
      source: 'fallback',
    ),
    IptvChannel(
      name: 'Россия 1',
      url: 'http://bethoven.af-stream.com:8080/s/pyxm92zq/rossija/video.m3u8',
      category: 'Общероссийские',
      source: 'fallback',
    ),
    IptvChannel(
      name: 'Россия 1 HD',
      url:
          'http://bethoven.af-stream.com:8080/s/pyxm92zq/rossija-hd/video.m3u8',
      category: 'Общероссийские',
      source: 'fallback',
    ),
    IptvChannel(
      name: 'НТВ',
      url: 'http://bethoven.af-stream.com:8080/s/pyxm92zq/ntv/video.m3u8',
      category: 'Общероссийские',
      source: 'fallback',
    ),
    IptvChannel(
      name: 'НТВ HD',
      url: 'http://bethoven.af-stream.com:8080/s/pyxm92zq/ntv-hd/video.m3u8',
      category: 'Общероссийские',
      source: 'fallback',
    ),
    IptvChannel(
      name: 'ТНТ',
      url: 'http://bethoven.af-stream.com:8080/s/pyxm92zq/TNT/video.m3u8',
      category: 'Общероссийские',
      source: 'fallback',
    ),
    IptvChannel(
      name: 'ТНТ HD',
      url: 'http://bethoven.af-stream.com:8080/s/pyxm92zq/tnt-hd/video.m3u8',
      category: 'Общероссийские',
      source: 'fallback',
    ),
    IptvChannel(
      name: 'СТС',
      url: 'http://bethoven.af-stream.com:8080/s/pyxm92zq/CTC/video.m3u8',
      category: 'Общероссийские',
      source: 'fallback',
    ),
    IptvChannel(
      name: 'ТВ3',
      url: 'http://bethoven.af-stream.com:8080/s/pyxm92zq/tv3/video.m3u8',
      category: 'Общероссийские',
      source: 'fallback',
    ),
    IptvChannel(
      name: 'РЕН ТВ',
      url: 'http://bethoven.af-stream.com:8080/s/pyxm92zq/ren-tv/video.m3u8',
      category: 'Общероссийские',
      source: 'fallback',
    ),
    IptvChannel(
      name: 'ТВЦ',
      url: 'http://bethoven.af-stream.com:8080/s/pyxm92zq/tvc/video.m3u8',
      category: 'Общероссийские',
      source: 'fallback',
    ),
    IptvChannel(
      name: 'Звезда',
      url: 'http://bethoven.af-stream.com:8080/s/pyxm92zq/zvezda/video.m3u8',
      category: 'Общероссийские',
      source: 'fallback',
    ),
    IptvChannel(
      name: '5 канал',
      url: 'http://bethoven.af-stream.com:8080/s/pyxm92zq/5kanal/video.m3u8',
      category: 'Общероссийские',
      source: 'fallback',
    ),
    IptvChannel(
      name: 'Пятница',
      url: 'http://bethoven.af-stream.com:8080/s/pyxm92zq/piatnica/video.m3u8',
      category: 'Общероссийские',
      source: 'fallback',
    ),
    IptvChannel(
      name: 'Домашний',
      url: 'http://bethoven.af-stream.com:8080/s/pyxm92zq/domashnij/video.m3u8',
      category: 'Общероссийские',
      source: 'fallback',
    ),
    IptvChannel(
      name: 'Мир',
      url: 'http://bethoven.af-stream.com:8080/s/pyxm92zq/mir/video.m3u8',
      category: 'Общероссийские',
      source: 'fallback',
    ),
    IptvChannel(
      name: 'ОТР',
      url: 'http://bethoven.af-stream.com:8080/s/pyxm92zq/otp/video.m3u8',
      category: 'Общероссийские',
      source: 'fallback',
    ),
    IptvChannel(
      name: 'Ю ТВ',
      url: 'http://bethoven.af-stream.com:8080/s/pyxm92zq/yu-tv/video.m3u8',
      category: 'Общероссийские',
      source: 'fallback',
    ),
    // Новости
    IptvChannel(
      name: 'Россия 24',
      url: 'http://bethoven.af-stream.com:8080/s/pyxm92zq/rossija24/video.m3u8',
      category: 'Новости',
      source: 'fallback',
    ),
    IptvChannel(
      name: 'РБК',
      url: 'http://bethoven.af-stream.com:8080/s/pyxm92zq/rbk/video.m3u8',
      category: 'Новости',
      source: 'fallback',
    ),
    IptvChannel(
      name: 'Мир 24',
      url: 'http://bethoven.af-stream.com:8080/s/pyxm92zq/mir-24/video.m3u8',
      category: 'Новости',
      source: 'fallback',
    ),
    // Кино
    IptvChannel(
      name: 'Кинопремьера HD',
      url:
          'http://bethoven.af-stream.com:8080/s/pyxm92zq/kinopremiera-hd/video.m3u8',
      category: 'Кино',
      source: 'fallback',
    ),
    IptvChannel(
      name: 'Кинохит',
      url: 'http://bethoven.af-stream.com:8080/s/pyxm92zq/kinohit/video.m3u8',
      category: 'Кино',
      source: 'fallback',
    ),
    IptvChannel(
      name: 'Киномикс',
      url: 'http://bethoven.af-stream.com:8080/s/pyxm92zq/kinomix/video.m3u8',
      category: 'Кино',
      source: 'fallback',
    ),
    IptvChannel(
      name: 'Киносемья',
      url: 'http://bethoven.af-stream.com:8080/s/pyxm92zq/kinosemja/video.m3u8',
      category: 'Кино',
      source: 'fallback',
    ),
    IptvChannel(
      name: 'Кинокомедия',
      url:
          'http://bethoven.af-stream.com:8080/s/pyxm92zq/kinokomedia/video.m3u8',
      category: 'Кино',
      source: 'fallback',
    ),
    IptvChannel(
      name: 'Дом Кино',
      url: 'http://bethoven.af-stream.com:8080/s/pyxm92zq/dom-kino/video.m3u8',
      category: 'Кино',
      source: 'fallback',
    ),
    IptvChannel(
      name: 'Мосфильм',
      url: 'http://bethoven.af-stream.com:8080/s/pyxm92zq/mosfilm/video.m3u8',
      category: 'Кино',
      source: 'fallback',
    ),
    IptvChannel(
      name: 'Русский Иллюзион',
      url:
          'http://bethoven.af-stream.com:8080/s/pyxm92zq/russkij-iluzion/video.m3u8',
      category: 'Кино',
      source: 'fallback',
    ),
    IptvChannel(
      name: 'Блокбастер HD',
      url:
          'http://bethoven.af-stream.com:8080/s/pyxm92zq/blokbaster-hd/video.m3u8',
      category: 'Кино',
      source: 'fallback',
    ),
    // Спорт
    IptvChannel(
      name: 'Матч ТВ',
      url: 'http://bethoven.af-stream.com:8080/s/pyxm92zq/match-tv/video.m3u8',
      category: 'Спорт',
      source: 'fallback',
    ),
    IptvChannel(
      name: 'Матч ТВ HD',
      url:
          'http://bethoven.af-stream.com:8080/s/pyxm92zq/match-tv-hd/video.m3u8',
      category: 'Спорт',
      source: 'fallback',
    ),
    IptvChannel(
      name: 'Матч! Арена',
      url:
          'http://bethoven.af-stream.com:8080/s/pyxm92zq/match-arena/video.m3u8',
      category: 'Спорт',
      source: 'fallback',
    ),
    IptvChannel(
      name: 'Матч! Игра',
      url:
          'http://bethoven.af-stream.com:8080/s/pyxm92zq/match-igra/video.m3u8',
      category: 'Спорт',
      source: 'fallback',
    ),
    IptvChannel(
      name: 'Матч! Боец',
      url:
          'http://bethoven.af-stream.com:8080/s/pyxm92zq/match-boec/video.m3u8',
      category: 'Спорт',
      source: 'fallback',
    ),
    IptvChannel(
      name: 'Eurosport 1',
      url: 'http://bethoven.af-stream.com:8080/s/pyxm92zq/eurosport/video.m3u8',
      category: 'Спорт',
      source: 'fallback',
    ),
    IptvChannel(
      name: 'Авто Плюс HD',
      url:
          'http://bethoven.af-stream.com:8080/s/pyxm92zq/auto-plus-hd/video.m3u8',
      category: 'Спорт',
      source: 'fallback',
    ),
    // Мультфильмы
    IptvChannel(
      name: 'Карусель',
      url: 'http://bethoven.af-stream.com:8080/s/pyxm92zq/karusel/video.m3u8',
      category: 'Мультфильмы',
      source: 'fallback',
    ),
    IptvChannel(
      name: 'Мульт',
      url: 'http://bethoven.af-stream.com:8080/s/pyxm92zq/mult/video.m3u8',
      category: 'Мультфильмы',
      source: 'fallback',
    ),
    IptvChannel(
      name: 'Детский мир',
      url:
          'http://bethoven.af-stream.com:8080/s/pyxm92zq/detskij-mir/video.m3u8',
      category: 'Мультфильмы',
      source: 'fallback',
    ),
    IptvChannel(
      name: 'Мультиландия',
      url:
          'http://bethoven.af-stream.com:8080/s/pyxm92zq/multimania/video.m3u8',
      category: 'Мультфильмы',
      source: 'fallback',
    ),
    // Познавательные
    IptvChannel(
      name: 'National Geographic',
      url: 'http://bethoven.af-stream.com:8080/s/pyxm92zq/nat-geo/video.m3u8',
      category: 'Познавательные',
      source: 'fallback',
    ),
    IptvChannel(
      name: 'Discovery Channel',
      url: 'http://bethoven.af-stream.com:8080/s/pyxm92zq/discovery/video.m3u8',
      category: 'Познавательные',
      source: 'fallback',
    ),
    IptvChannel(
      name: 'History HD',
      url:
          'http://bethoven.af-stream.com:8080/s/pyxm92zq/history-hd/video.m3u8',
      category: 'Познавательные',
      source: 'fallback',
    ),
    IptvChannel(
      name: 'Моя планета',
      url:
          'http://bethoven.af-stream.com:8080/s/pyxm92zq/moya-planeta/video.m3u8',
      category: 'Познавательные',
      source: 'fallback',
    ),
    IptvChannel(
      name: 'Наука',
      url: 'http://bethoven.af-stream.com:8080/s/pyxm92zq/nauka/video.m3u8',
      category: 'Познавательные',
      source: 'fallback',
    ),
    IptvChannel(
      name: 'Зал Суда HD',
      url:
          'http://bethoven.af-stream.com:8080/s/pyxm92zq/zal-suda-hd/video.m3u8',
      category: 'Познавательные',
      source: 'fallback',
    ),
    // Музыкальные
    IptvChannel(
      name: 'Музыка Первого',
      url:
          'http://bethoven.af-stream.com:8080/s/pyxm92zq/muzyka-pervogo/video.m3u8',
      category: 'Музыкальные',
      source: 'fallback',
    ),
    IptvChannel(
      name: 'RU TV',
      url: 'http://bethoven.af-stream.com:8080/s/pyxm92zq/ru-tv/video.m3u8',
      category: 'Музыкальные',
      source: 'fallback',
    ),
    IptvChannel(
      name: 'Муз-ТВ',
      url: 'http://bethoven.af-stream.com:8080/s/pyxm92zq/muz-tv/video.m3u8',
      category: 'Музыкальные',
      source: 'fallback',
    ),
    IptvChannel(
      name: 'Europa Plus TV',
      url:
          'http://bethoven.af-stream.com:8080/s/pyxm92zq/evropa-plus-tv/video.m3u8',
      category: 'Музыкальные',
      source: 'fallback',
    ),
    IptvChannel(
      name: 'Шансон ТВ',
      url:
          'http://bethoven.af-stream.com:8080/s/pyxm92zq/shanson-tv/video.m3u8',
      category: 'Музыкальные',
      source: 'fallback',
    ),
    // ── Беларусь ──
    IptvChannel(name: 'ОНТ', url: 'http://ont.dc.beltelecom.by/ont/ont.stream/playlist.m3u8', category: 'Беларусь', country: 'Беларусь', source: 'fallback'),
    IptvChannel(name: 'Беларусь 1', url: 'https://ngtrk.dc.beltelecom.by/ngtrk/smil:belarus1.smil/playlist.m3u8', category: 'Беларусь', country: 'Беларусь', source: 'fallback'),
    IptvChannel(name: 'Беларусь 3', url: 'https://ngtrk.dc.beltelecom.by/ngtrk/smil:belarus3.smil/playlist.m3u8', category: 'Беларусь', country: 'Беларусь', source: 'fallback'),
    IptvChannel(name: 'Беларусь 24', url: 'https://ngtrk.dc.beltelecom.by/ngtrk/smil:belarus24.smil/playlist.m3u8', category: 'Беларусь', country: 'Беларусь', source: 'fallback'),
    IptvChannel(name: 'СТВ', url: 'http://ctv.dc.beltelecom.by/ctv/ctv.stream/playlist.m3u8', category: 'Беларусь', country: 'Беларусь', source: 'fallback'),
    IptvChannel(name: 'НТВ Беларусь', url: 'http://194.158.222.36:6107', category: 'Беларусь', country: 'Беларусь', source: 'fallback'),
  ];
}
