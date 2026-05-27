import 'dart:convert';
import 'dart:io';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/iptv_channel.dart';
import 'log_service.dart';

class IptvService {
  static const _cacheKey = 'iptv_channels_cache_v1';
  static const _cacheTimeKey = 'iptv_channels_cache_time_v1';
  static const _cacheTtl = Duration(hours: 12);

  // Легальные публичные плейлисты IPTV.
  // При недоступности используем встроенный список каналов (не требует интернета).
  static const _sources = [
    'https://sat-portal.com/upload/rus_22.05.2026.m3u8',
    'https://sat-portal.com/upload/by_%2020.02.2026.m3u8',
  ];

  // Фолбэк-источники (если основные недоступны)
  static const _fallbackSources = [
    'https://iptv-org.github.io/iptv/languages/rus.m3u',
  ];

  static const categoryOrder = [
    'Все',
    'Избранное',
    'Россия',
    'Общероссийские',
    'Беларусь',
    'Общие',
    'Кино',
    'Детские',
    'Спорт',
    'Музыка',
    'Музыкальные',
    'Познавательные',
    'Новости',
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

    // Пробуем основные источники
    List<IptvChannel>? result = await _tryLoad(_sources);
    // Если не вышло — фолбэки
    result ??= await _tryLoad(_fallbackSources);
    // Если всё сломалось — кэш или fallback-список
    if (result == null || result.isEmpty) {
      LogService.warn(LogService.iptv, 'IPTV: все источники недоступны');
      final cached = _readCache(prefs, ignoreTtl: true);
      if (cached.isNotEmpty) return cached;
      return fallbackChannels;
    }
    await _saveCache(prefs, result);
    return result;
  }

  static Future<List<IptvChannel>?> _tryLoad(List<String> sources) async {
    for (final source in sources) {
      try {
        final body = await _download(source);
        final channels = parseM3u(body, source: source);
        if (channels.isNotEmpty) {
          final cleaned = _dedupe(channels);
          if (cleaned.isNotEmpty) return cleaned;
        }
      } catch (e) {
        LogService.warn(LogService.iptv, 'IPTV: ошибка загрузки $source', e);
      }
    }
    return null;
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
      final autoCountry = _detectCountry(source);
      final country = attrs['tvg-country']?.isNotEmpty == true
          ? attrs['tvg-country']!
          : autoCountry;
      out.add(IptvChannel(
        name: name,
        url: line,
        category: category,
        logo: attrs['tvg-logo'] ?? '',
        country: country,
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

  static String _detectCountry(String source) {
    final s = source.toLowerCase();
    if (s.contains('belarus') || s.contains('by_') || s.contains('/by/')) {
      return 'Беларусь';
    }
    if (s.contains('rus_') || s.contains('/rus') || s.contains('russia')) {
      return 'Россия';
    }
    return '';
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
    } catch (e) {
      LogService.warn(LogService.iptv, 'IPTV: ошибка чтения кэша', e);
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
      category: 'Общероссийские',
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
      category: 'Музыка',
      source: 'fallback',
    ),
    // ── Беларусь (встроенные) ──
    IptvChannel(name: 'Беларусь 1', url: 'https://edge50.dc.beltelecom.by/ngtrk/smil:belarus1.smil/chunklist_b5160000_sleng.m3u8', category: 'Беларусь', country: 'Беларусь', logo: '', source: 'fallback'),
    IptvChannel(name: 'Беларусь 3 HD', url: 'https://edge50.dc.beltelecom.by/ngtrk/smil:belarus3.smil/chunklist_b5160000_sleng.m3u8', category: 'Беларусь', country: 'Беларусь', logo: '', source: 'fallback'),
    IptvChannel(name: 'НТВ Беларусь', url: 'http://194.158.222.36:6107', category: 'Беларусь', country: 'Беларусь', logo: '', source: 'fallback'),
    IptvChannel(name: 'Беларусь 24', url: 'https://edge53.dc.beltelecom.by/ngtrk/smil:belarus24.smil/playlist.m3u8', category: 'Беларусь', country: 'Беларусь', logo: '', source: 'fallback'),
    IptvChannel(name: 'Беларусь 5', url: 'https://edge59.dc.beltelecom.by/ngtrk/smil:belarus5int.smil/playlist.m3u8', category: 'Беларусь', country: 'Беларусь', logo: '', source: 'fallback'),
    IptvChannel(name: 'Первый информационный', url: 'https://ngtrk.dc.beltelecom.by/ngtrk/smil:informacionnyy.smil/playlist.m3u8', category: 'Беларусь', country: 'Беларусь', logo: '', source: 'fallback'),
    IptvChannel(name: 'СТВ HD', url: 'http://ctv.dc.beltelecom.by/ctv/ctv.stream/playlist.m3u8', category: 'Беларусь', country: 'Беларусь', logo: '', source: 'fallback'),
    IptvChannel(name: 'Беларусь 5 (Спорт)', url: 'https://ngtrk.dc.beltelecom.by/ngtrk/smil:belarus5.smil/playlist.m3u8', category: 'Спорт', country: 'Беларусь', logo: '', source: 'fallback'),
    IptvChannel(name: '1Mus', url: 'http://hz1.teleport.cc/HLS/HD.m3u8', category: 'Музыка', country: 'Беларусь', logo: '', source: 'fallback'),
    IptvChannel(name: 'Belros', url: 'https://live2.mediacdn.ru/sr1/tro/playlist.m3u8', category: 'Беларусь', country: 'Беларусь', logo: '', source: 'fallback'),
    IptvChannel(name: 'Первый музыкальный', url: 'http://rtmp.one.by:1200', category: 'Музыка', country: 'Беларусь', logo: '', source: 'fallback'),
    IptvChannel(name: 'Belsat TV', url: 'https://ythls.armelin.one/channel/UCRokSp8CGOuQO4R0F1RxRGg.m3u8', category: 'Беларусь', country: 'Беларусь', logo: '', source: 'fallback'),
  ];
}
