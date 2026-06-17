import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart' show rootBundle;
import '../models/iptv_channel.dart';
import 'log_service.dart';

class IptvService {
  static const _embeddedAssets = <String, String>{
    'all': 'assets/iptv/playlist.m3u',
  };

  static const categoryOrder = [
    'Все', 'Избранное', 'Россия', 'Беларусь',
    'Общероссийские', 'Кино', 'Детские', 'Спорт', 'Музыка', 
    'Познавательные', 'Развлекательные', 'Новости', 'Региональные', 
    'Взрослые', 'Разное',
  ];

  static Future<List<IptvChannel>> loadChannels({bool forceRefresh = false}) async {
    final all = <IptvChannel>[];
    for (final entry in _embeddedAssets.entries) {
      try {
        final body = await rootBundle.loadString(entry.value);
        if (body.isNotEmpty) all.addAll(parseM3u(body, source: entry.key));
      } catch (e) {
        LogService.warn(LogService.iptv, 'IPTV: asset ${entry.key}', e);
      }
    }
    // Раскрываем мета-плейлисты (.m3u) — скачиваем и сопоставляем каналы по имени
    final resolved = await _resolveMetaPlaylists(all);
    if (forceRefresh) {
      for (final url in ['https://sat-portal.com/upload/rus_22.05.2026.m3u8']) {
        try {
          final body = await _download(url);
          if (body.isNotEmpty) resolved.addAll(parseM3u(body, source: url));
        } catch (_) {}
      }
    }
    final cleaned = _dedupe(resolved);
    return cleaned.isNotEmpty ? cleaned : fallbackChannels;
  }

  /// Скачивает мета-плейлисты (.m3u) и подменяет URL каналов на реальные потоки
  static Future<List<IptvChannel>> _resolveMetaPlaylists(List<IptvChannel> channels) async {
    // Находим каналы с мета-плейлистами (URL заканчивается на .m3u, но не .m3u8)
    final metaUrls = <String>{};
    for (final ch in channels) {
      final u = ch.url.toLowerCase();
      if (u.endsWith('.m3u') && !u.endsWith('.m3u8')) {
        metaUrls.add(ch.url);
      }
    }
    if (metaUrls.isEmpty) return channels;

    // Скачиваем и парсим каждый мета-плейлист
    final metaCache = <String, Map<String, String>>{}; // url -> {name: streamUrl}
    for (final url in metaUrls) {
      try {
        final body = await _download(url);
        final entries = parseM3u(body, source: url);
        final map = <String, String>{};
        for (final e in entries) {
          map[e.name.toLowerCase()] = e.url;
          // Добавляем вариации имён для лучшего совпадения
          final simple = e.name.toLowerCase().replaceAll(RegExp(r'\s*\(.*?\)\s*'), '').trim();
          if (simple != e.name.toLowerCase()) map[simple] = e.url;
        }
        metaCache[url] = map;
      } catch (_) {}
    }

    // Подменяем URL для каналов, у которых нашёлся реальный поток
    final result = <IptvChannel>[];
    for (final ch in channels) {
      final map = metaCache[ch.url];
      if (map != null) {
        // Ищем совпадение по имени
        final nameKey = ch.name.toLowerCase();
        final simpleKey = nameKey.replaceAll(RegExp(r'\s*\(.*?\)\s*'), '').trim();
        var streamUrl = map[nameKey] ?? map[simpleKey];
        if (streamUrl == null) {
          // Частичное совпадение
          for (final k in map.keys) {
            if (k.contains(nameKey) || nameKey.contains(k)) {
              streamUrl = map[k];
              break;
            }
          }
        }
        if (streamUrl != null) {
          result.add(IptvChannel(
            name: ch.name, url: streamUrl, category: ch.category,
            logo: ch.logo, country: ch.country, language: ch.language, source: ch.source,
          ));
        } else {
          result.add(ch); // не нашли — оставляем как есть
        }
      } else {
        result.add(ch);
      }
    }
    return result;
  }

  static List<String> categoriesFor(List<IptvChannel> channels) {
    final set = channels.map((e) => e.category).where((e) => e.isNotEmpty).toSet();
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
      if (resp.statusCode != 200) throw Exception('IPTV HTTP ${resp.statusCode}');
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
    String pendingGroup = '';
    
    for (final rawLine in lines) {
      final line = rawLine.trim();
      if (line.isEmpty) continue;
      
      if (line.startsWith('#EXTINF')) {
        pendingAttrs = _parseAttrs(line);
        final comma = line.indexOf(',');
        pendingName = comma >= 0 ? line.substring(comma + 1).trim() : '';
        pendingGroup = ''; // Reset group
        continue;
      }
      
      if (line.startsWith('#EXTGRP:')) {
        pendingGroup = line.substring(8).trim();
        continue;
      }
      
      if (line.startsWith('#')) continue;
      if (!line.startsWith('http://') && !line.startsWith('https://')) continue;
      
      final attrs = pendingAttrs ?? const <String, String>{};
      final name = _firstNonEmpty([pendingName, attrs['tvg-name'] ?? '', attrs['tvg-id'] ?? '', Uri.tryParse(line)?.host ?? '']);
      final group = _firstNonEmpty([pendingGroup, attrs['group-title'] ?? '']);
      
      final category = normalizeCategory(group, name);
      final autoCountry = _detectCountry(source);
      final country = attrs['tvg-country']?.isNotEmpty == true ? attrs['tvg-country']! : autoCountry;
      
      out.add(IptvChannel(name: name, url: line, category: category,
          logo: attrs['tvg-logo'] ?? '', country: country, language: attrs['tvg-language'] ?? '', source: source));
      pendingAttrs = null; pendingName = ''; pendingGroup = '';
    }
    return out;
  }

  static String _detectCountry(String source) {
    final s = source.toLowerCase();
    if (s.contains('belarus') || s.contains('by_') || s.contains('/by/')) return 'Беларусь';
    if (s.contains('rus_') || s.contains('/rus') || s.contains('russia')) return 'Россия';
    return '';
  }

  static Map<String, String> _parseAttrs(String line) {
    final attrs = <String, String>{};
    for (final m in RegExp(r'([\w-]+)="([^"]*)"').allMatches(line)) {
      attrs[(m.group(1) ?? '').toLowerCase()] = m.group(2) ?? '';
    }
    return attrs;
  }

  static String normalizeCategory(String group, String name) {
    final s = '$group $name'.toLowerCase();
    if (_hasAny(s, ['news', 'новост', 'вести', 'rt ', 'мир 24', 'rbc', 'рбк'])) return 'Новости';
    if (_hasAny(s, ['sport', 'спорт', 'football', 'футбол', 'хоккей', 'mma'])) return 'Спорт';
    if (_hasAny(s, ['kids', 'детск', 'cartoon', 'мульт', 'disney', 'nick'])) return 'Детские';
    if (_hasAny(s, ['movie', 'cinema', 'film', 'кино', 'сериал'])) return 'Кино';
    if (_hasAny(s, ['music', 'музык', 'музыка', 'radio', 'радио'])) return 'Музыка';
    if (_hasAny(s, ['documentary', 'science', 'history', 'travel', 'docu', 'познав', 'история', 'наука'])) return 'Познавательные';
    if (_hasAny(s, ['regional', 'local', 'регион', 'город', 'област'])) return 'Региональные';
    if (_hasAny(s, ['entertainment', 'развлек', 'general', 'общий'])) return 'Развлекательные';
    if (_hasAny(s, ['adult', 'взросл', '18+'])) return 'Взрослые';
    if (_hasAny(s, ['belarus', 'белар'])) return 'Беларусь';
    final t = group.trim();
    return t.isNotEmpty ? t[0].toUpperCase() + t.substring(1) : 'Разное';
  }

  static bool _hasAny(String value, List<String> needles) {
    for (final n in needles) { if (value.contains(n)) return true; }
    return false;
  }

  static String _firstNonEmpty(List<String> values) {
    for (final v in values) { final t = v.trim(); if (t.isNotEmpty) return t; }
    return 'IPTV канал';
  }

  static List<IptvChannel> _dedupe(List<IptvChannel> channels) {
    final seen = <String>{};
    final out = <IptvChannel>[];
    for (final ch in channels) {
      final url = ch.url.trim();
      final key = url.toLowerCase().endsWith('.m3u') ? '${ch.name.toLowerCase()}|$url' : url;
      if (url.isEmpty || seen.contains(key)) continue;
      seen.add(key); out.add(ch);
    }
    out.sort((a, b) {
      final ca = categoryOrder.indexOf(a.category), cb = categoryOrder.indexOf(b.category);
      final ai = ca < 0 ? 999 : ca, bi = cb < 0 ? 999 : cb;
      if (ai != bi) return ai.compareTo(bi);
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return out;
  }

  static const fallbackChannels = [
    IptvChannel(name: 'Первый канал', url: 'http://bethoven.af-stream.com:8080/s/pyxm92zq/pervyj/video.m3u8', category: 'Общероссийские', country: 'Россия', source: 'fallback'),
    IptvChannel(name: 'Россия 1', url: 'http://bethoven.af-stream.com:8080/s/pyxm92zq/rossija/video.m3u8', category: 'Общероссийские', country: 'Россия', source: 'fallback'),
    IptvChannel(name: 'НТВ', url: 'http://bethoven.af-stream.com:8080/s/pyxm92zq/ntv/video.m3u8', category: 'Общероссийские', country: 'Россия', source: 'fallback'),
    IptvChannel(name: 'ОНТ', url: 'http://bethoven.af-stream.com:8080/s/pyxm92zq/ont-by/video.m3u8', category: 'Беларусь', country: 'Беларусь', source: 'fallback'),
    IptvChannel(name: 'Беларусь 1', url: 'http://bethoven.af-stream.com:8080/s/pyxm92zq/belarus1-by/video.m3u8', category: 'Беларусь', country: 'Беларусь', source: 'fallback'),
    IptvChannel(name: 'Беларусь 24', url: 'http://bethoven.af-stream.com:8080/s/pyxm92zq/belarus-24/video.m3u8', category: 'Беларусь', country: 'Беларусь', source: 'fallback'),
    IptvChannel(name: 'СТВ', url: 'http://bethoven.af-stream.com:8080/s/pyxm92zq/stv-by-hd/video.m3u8', category: 'Беларусь', country: 'Беларусь', source: 'fallback'),
  ];
}
