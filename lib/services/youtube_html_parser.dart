/// Прямой HTML-парсер YouTube.
/// HTTP-запросы с клиента (совпадает IP) → извлечение ytInitialData → парсинг видео.
/// Без InnerTube, без серверного прокси.
library;

import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/youtube_video.dart';

const _ytOrigin = 'https://www.youtube.com';
const _userAgent =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36';
const _acceptLang = 'ru-RU,ru;q=0.9,en-US;q=0.8,en;q=0.7';

class YouTubeHtmlParser {
  final String _cookies;

  YouTubeHtmlParser(this._cookies);

  /// GET-запрос к YouTube (консистентный IP)
  Future<String> _get(String url) async {
    final uri = Uri.parse(url);
    final headers = {
      'User-Agent': _userAgent,
      'Accept-Language': _acceptLang,
      'Accept':
          'text/html,application/xhtml+xml,application/xml;q=0.9,image/webp,*/*;q=0.8',
      if (_cookies.isNotEmpty) 'Cookie': _cookies,
    };
    final resp = await http.get(uri, headers: headers).timeout(
      const Duration(seconds: 30),
    );
    if (resp.statusCode != 200) {
      throw Exception('YouTube HTTP ${resp.statusCode}');
    }
    return resp.body;
  }

  /// Извлечь ytInitialData из HTML
  Map<String, dynamic>? _extractData(String html) {
    final patterns = [
      RegExp(r'(?:var\s+)?ytInitialData\s*=\s*\{'),
      RegExp(r'window\["ytInitialData"\]\s*=\s*\{'),
    ];
    Match? match;
    for (final p in patterns) {
      match = p.firstMatch(html);
      if (match != null) break;
    }
    if (match == null) return null;

    final start = match.end - 1; // позиция {
    var depth = 0;
    var inString = false;
    var escape = false;
    for (var i = start; i < html.length; i++) {
      final c = html[i];
      if (escape) {
        escape = false;
        continue;
      }
      if (c == '\\') {
        escape = true;
        continue;
      }
      if (c == '"' && !escape) {
        inString = !inString;
        continue;
      }
      if (inString) continue;
      if (c == '{') {
        depth++;
      } else if (c == '}') {
        depth--;
        if (depth == 0) {
          final jsonStr = html.substring(start, i + 1);
          try {
            return (json.decode(jsonStr) as Map).cast<String, dynamic>();
          } catch (_) {
            continue;
          }
        }
      }
    }
    return null;
  }

  /// Парсинг одного видео
  YouTubeVideo _parseVideo(Map r) {
    final vid = (r['videoId'] ?? '').toString();

    // Заголовок
    String title = '';
    final titleObj = r['title'];
    if (titleObj is Map) {
      title = (titleObj['simpleText'] ?? '').toString();
      if (title.isEmpty) {
        final runs = titleObj['runs'];
        if (runs is List) {
          title = runs
              .whereType<Map>()
              .map((x) => (x['text'] ?? '').toString())
              .join();
        }
      }
    }
    if (title.isEmpty) {
      title = ((r['headline'] as Map?)?.let((h) => h['simpleText']) ?? '')
          .toString();
    }

    // Канал
    String channel = '';
    for (final ok in ['ownerText', 'shortBylineText', 'longBylineText']) {
      final owner = r[ok];
      if (owner is Map) {
        final runs = owner['runs'];
        if (runs is List) {
          for (final x in runs) {
            if (x is Map) {
              channel = (x['text'] ?? '').toString();
              if (channel.isNotEmpty) break;
            }
          }
        }
      }
      if (channel.isNotEmpty) break;
    }

    // Превью
    String thumb = '';
    final thumbObj = r['thumbnail'];
    if (thumbObj is Map) {
      final thumbs = thumbObj['thumbnails'];
      if (thumbs is List && thumbs.isNotEmpty) {
        thumb = ((thumbs.last as Map)['url'] ?? '').toString();
      }
    }
    if (thumb.isEmpty && vid.isNotEmpty) {
      thumb = 'https://i.ytimg.com/vi/$vid/hqdefault.jpg';
    }

    // Просмотры
    String views = '';
    final vo = r['viewCountText'] ?? r['shortViewCountText'];
    if (vo is Map) {
      views = (vo['simpleText'] ?? '').toString();
      if (views.isEmpty) {
        final runs = vo['runs'];
        if (runs is List) {
          views = runs
              .whereType<Map>()
              .map((x) => (x['text'] ?? '').toString())
              .join();
        }
      }
    }

    // Длительность
    int duration = 0;
    final durObj = r['lengthText'];
    if (durObj is Map) {
      String durText = (durObj['simpleText'] ?? '').toString();
      if (durText.isEmpty) {
        durText = ((durObj['accessibility'] as Map?)
                ?.let((a) => a['accessibilityData'] as Map?)
                ?.let((ad) => ad['label']) ??
            '')
            .toString();
      }
      // "3:45" → 225, "1:23:45" → 5025
      final parts = durText
          .split(RegExp(r'[:\s]'))
          .where((p) => RegExp(r'^\d+$').hasMatch(p))
          .map(int.parse)
          .toList();
      if (parts.length == 2) duration = parts[0] * 60 + parts[1];
      if (parts.length == 3) {
        duration = parts[0] * 3600 + parts[1] * 60 + parts[2];
      }
    }

    return YouTubeVideo(
      id: vid,
      title: title.isNotEmpty ? title : 'Video $vid',
      channel: channel,
      viewsText: views,
      duration: duration,
      thumbnail: thumb,
      url: vid.isNotEmpty ? '$_ytOrigin/watch?v=$vid' : '',
    );
  }

  /// Извлечение видео из ytInitialData
  List<YouTubeVideo> _extractVideos(Map data) {
    final videos = <YouTubeVideo>[];

    void tryContainer(Map container) {
      final tabs = container['tabs'];
      if (tabs is! List) return;
      for (final tab in tabs) {
        if (tab is! Map) continue;
        final tr = (tab['tabRenderer'] ?? tab['expandableTabRenderer']);
        if (tr is! Map) continue;
        final tc = tr['content'];
        if (tc is! Map) continue;

        // richGridRenderer
        final rg = tc['richGridRenderer'];
        if (rg is Map) {
          final contents = rg['contents'];
          if (contents is List) {
            for (final item in contents) {
              if (item is! Map) continue;
              if (item.containsKey('richItemRenderer')) {
                final content =
                    (item['richItemRenderer'] as Map)['content'];
                if (content is Map) {
                  for (final k in [
                    'videoRenderer',
                    'reelItemRenderer',
                    'compactVideoRenderer'
                  ]) {
                    if (content.containsKey(k)) {
                      videos.add(_parseVideo(content[k] as Map));
                      break;
                    }
                  }
                }
              } else if (item.containsKey('videoRenderer')) {
                videos.add(_parseVideo(item['videoRenderer'] as Map));
              } else if (item.containsKey('compactVideoRenderer')) {
                videos
                    .add(_parseVideo(item['compactVideoRenderer'] as Map));
              }
            }
          }
        }

        // sectionListRenderer
        final sl = tc['sectionListRenderer'];
        if (sl is Map) {
          final sections = sl['contents'];
          if (sections is List) {
            for (final sec in sections) {
              if (sec is! Map) continue;
              final isr = sec['itemSectionRenderer'];
              if (isr is Map) {
                final items = isr['contents'];
                if (items is List) {
                  for (final item in items) {
                    if (item is! Map) continue;
                    for (final k in [
                      'videoRenderer',
                      'compactVideoRenderer'
                    ]) {
                      if (item.containsKey(k)) {
                        videos.add(_parseVideo(item[k] as Map));
                        break;
                      }
                    }
                  }
                }
              }
            }
          }
        }

        // shelfRenderer (horizontalList)
        if (rg is Map) {
          for (final item in (rg['contents'] as List? ?? [])) {
            if (item is! Map || !item.containsKey('shelfRenderer')) continue;
            final sr = item['shelfRenderer'] as Map;
            final sc = sr['content'];
            if (sc is! Map) continue;
            final hl = sc['horizontalListRenderer'];
            if (hl is Map) {
              for (final hi in (hl['items'] as List? ?? [])) {
                if (hi is! Map) continue;
                for (final k in [
                  'videoRenderer',
                  'compactVideoRenderer',
                  'gridVideoRenderer'
                ]) {
                  if (hi.containsKey(k)) {
                    videos.add(_parseVideo(hi[k] as Map));
                    break;
                  }
                }
              }
            }
          }
        }
      }
    }

    final contents = data['contents'];
    if (contents is Map) {
      tryContainer(
          (contents['twoColumnBrowseResultsRenderer'] as Map?) ?? {});
      if (videos.isEmpty) {
        tryContainer(
            (contents['singleColumnBrowseResultsRenderer'] as Map?) ??
                {});
      }
    }

    // Рекурсивный fallback
    if (videos.isEmpty) {
      _searchRecursive(data, videos, 0);
    }

    return videos;
  }

  void _searchRecursive(dynamic obj, List<YouTubeVideo> out, int depth) {
    if (depth > 10 || out.length > 100) return;
    if (obj is Map) {
      for (final k in [
        'videoRenderer',
        'reelItemRenderer',
        'compactVideoRenderer'
      ]) {
        if (obj.containsKey(k)) {
          out.add(_parseVideo(obj[k] as Map));
        }
      }
      for (final v in obj.values) {
        _searchRecursive(v, out, depth + 1);
      }
    } else if (obj is List) {
      for (final item in obj) {
        _searchRecursive(item, out, depth + 1);
      }
    }
  }

  // ─── Публичные методы ─────────────────────────────────────────

  Future<List<YouTubeVideo>> getHome({int limit = 24}) async {
    final html = await _get('$_ytOrigin/');
    final data = _extractData(html);
    if (data == null) return [];
    return _extractVideos(data).take(limit).toList();
  }

  Future<List<YouTubeVideo>> getSubscriptions({int limit = 30}) async {
    if (!_cookies.contains('SAPISID=')) {
      throw Exception('AUTH_REQUIRED');
    }
    final html = await _get('$_ytOrigin/feed/subscriptions');
    if (html.contains('/ServiceLogin') || html.contains('accounts.google.com')) {
      throw Exception('AUTH_ERROR_401');
    }
    final data = _extractData(html);
    if (data == null) return [];
    return _extractVideos(data).take(limit).toList();
  }

  Future<List<YouTubeVideo>> getShorts({int limit = 20}) async {
    final html =
        await _get('$_ytOrigin/results?search_query=%23shorts');
    final data = _extractData(html);
    if (data == null) return [];
    final all = _extractVideos(data);
    final shorts = all.where((v) => v.duration > 0 && v.duration <= 60);
    return (shorts.isNotEmpty ? shorts : all).take(limit).toList();
  }
}

extension _Let<T> on T {
  R? let<R>(R Function(T it) fn) => fn(this);
}
