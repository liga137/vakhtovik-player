/// YouTube HTML-парсер через общий WebView (тот же браузерный процесс, те же куки).
/// Не создаёт отдельных WebView — использует WebView из youtube_search_screen.
library;

import 'dart:async';
import 'dart:convert';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import '../models/youtube_video.dart';

const _ytOrigin = 'https://www.youtube.com';

class YouTubeHtmlParser {
  static InAppWebViewController? _controller;
  static Completer<Map<String, dynamic>?>? _pending;
  static String? _pendingUrl;

  /// Вызвать из youtube_search_screen при создании скрытого WebView
  static void setController(InAppWebViewController c) {
    _controller = c;
  }

  /// Вызвать из youtube_search_screen.onLoadStop
  static void onPageLoaded(String? url) {
    if (url == null || _pending == null || _pending!.isCompleted) return;
    // Ждём именно тот URL который запрашивали (без query-параметров)
    final clean = url.split('?').first;
    final pending = _pendingUrl?.split('?').first;
    if (clean != pending) return;

    _controller?.evaluateJavascript(
      source: 'JSON.stringify(window.ytInitialData || null)',
    ).then((result) {
      if (result != null && result.toString() != 'null' && !_pending!.isCompleted) {
        _pending!.complete((json.decode(result.toString()) as Map).cast<String, dynamic>());
      } else if (!_pending!.isCompleted) {
        _pending!.complete(null);
      }
    });
  }

  static Future<Map<String, dynamic>?> _loadUrl(String url) async {
    _pending?.complete(null);
    _pending = Completer<Map<String, dynamic>?>();
    _pendingUrl = url;
    _controller?.loadUrl(urlRequest: URLRequest(url: WebUri(url)));
    try {
      return await _pending!.future.timeout(
        const Duration(seconds: 20),
        onTimeout: () => null,
      );
    } finally {
      _pending = null;
      _pendingUrl = null;
    }
  }

  // ─── Парсинг ────────────────────────────────────────────────────

  static YouTubeVideo _parseVideo(Map r) {
    final vid = (r['videoId'] ?? '').toString();
    String title = '';
    final to = r['title'];
    if (to is Map) {
      title = (to['simpleText'] ?? '').toString();
      if (title.isEmpty) {
        final runs = to['runs'];
        if (runs is List) {
          title = runs.whereType<Map>().map((x) => (x['text'] ?? '').toString()).join();
        }
      }
    }
    if (title.isEmpty) title = ((r['headline'] as Map?)?.let((h) => h['simpleText']) ?? '').toString();
    String channel = '';
    for (final ok in ['ownerText', 'shortBylineText', 'longBylineText']) {
      final ow = r[ok];
      if (ow is Map) {
        final runs = ow['runs'];
        if (runs is List) {
          for (final x in runs) {
            if (x is Map) { channel = (x['text'] ?? '').toString(); if (channel.isNotEmpty) break; }
          }
        }
      }
      if (channel.isNotEmpty) break;
    }
    String thumb = '';
    final thumbObj = r['thumbnail'];
    if (thumbObj is Map) {
      final thumbs = thumbObj['thumbnails'];
      if (thumbs is List && thumbs.isNotEmpty) thumb = ((thumbs.last as Map)['url'] ?? '').toString();
    }
    if (thumb.isEmpty && vid.isNotEmpty) thumb = 'https://i.ytimg.com/vi/$vid/hqdefault.jpg';
    String views = '';
    final vo = r['viewCountText'] ?? r['shortViewCountText'];
    if (vo is Map) {
      views = (vo['simpleText'] ?? '').toString();
      if (views.isEmpty) {
        final runs = vo['runs'];
        if (runs is List) views = runs.whereType<Map>().map((x) => (x['text'] ?? '').toString()).join();
      }
    }
    int duration = 0;
    final durObj = r['lengthText'];
    if (durObj is Map) {
      String durText = (durObj['simpleText'] ?? '').toString();
      if (durText.isEmpty) durText = ((durObj['accessibility'] as Map?)?.let((a) => a['accessibilityData'] as Map?)?.let((ad) => ad['label']) ?? '').toString();
      final parts = durText.split(RegExp(r'[:\s]')).where((p) => RegExp(r'^\d+$').hasMatch(p)).map(int.parse).toList();
      if (parts.length == 2) duration = parts[0] * 60 + parts[1];
      if (parts.length == 3) duration = parts[0] * 3600 + parts[1] * 60 + parts[2];
    }
    return YouTubeVideo(id: vid, title: title.isNotEmpty ? title : 'Video $vid', channel: channel, viewsText: views, duration: duration, thumbnail: thumb, url: vid.isNotEmpty ? '$_ytOrigin/watch?v=$vid' : '');
  }

  static List<YouTubeVideo> _extractVideos(Map data) {
    final videos = <YouTubeVideo>[];
    void tryContainer(Map container) {
      final tabs = container['tabs'];
      if (tabs is! List) return;
      for (final tab in tabs) {
        if (tab is! Map) continue;
        final tr = tab['tabRenderer'] ?? tab['expandableTabRenderer'];
        if (tr is! Map) continue;
        final tc = tr['content'];
        if (tc is! Map) continue;
        final rg = tc['richGridRenderer'];
        if (rg is Map) {
          for (final item in (rg['contents'] as List? ?? [])) {
            if (item is! Map) continue;
            if (item.containsKey('richItemRenderer')) {
              final content = (item['richItemRenderer'] as Map)['content'];
              if (content is Map) for (final k in ['videoRenderer', 'reelItemRenderer', 'compactVideoRenderer']) {
                if (content.containsKey(k)) { videos.add(_parseVideo(content[k] as Map)); break; }
              }
            } else if (item.containsKey('videoRenderer')) videos.add(_parseVideo(item['videoRenderer'] as Map));
            else if (item.containsKey('compactVideoRenderer')) videos.add(_parseVideo(item['compactVideoRenderer'] as Map));
          }
        }
        final sl = tc['sectionListRenderer'];
        if (sl is Map) for (final sec in (sl['contents'] as List? ?? [])) {
          if (sec is! Map) continue;
          final isr = sec['itemSectionRenderer'];
          if (isr is Map) for (final item in (isr['contents'] as List? ?? [])) {
            if (item is! Map) continue;
            for (final k in ['videoRenderer', 'compactVideoRenderer']) if (item.containsKey(k)) { videos.add(_parseVideo(item[k] as Map)); break; }
          }
        }
        if (rg is Map) for (final item in (rg['contents'] as List? ?? [])) {
          if (item is! Map || !item.containsKey('shelfRenderer')) continue;
          final sr = item['shelfRenderer'] as Map;
          final sc = sr['content'];
          if (sc is! Map) continue;
          final hl = sc['horizontalListRenderer'];
          if (hl is Map) for (final hi in (hl['items'] as List? ?? [])) {
            if (hi is! Map) continue;
            for (final k in ['videoRenderer', 'compactVideoRenderer', 'gridVideoRenderer']) if (hi.containsKey(k)) { videos.add(_parseVideo(hi[k] as Map)); break; }
          }
        }
      }
    }
    final contents = data['contents'];
    if (contents is Map) {
      tryContainer((contents['twoColumnBrowseResultsRenderer'] as Map?) ?? {});
      if (videos.isEmpty) tryContainer((contents['singleColumnBrowseResultsRenderer'] as Map?) ?? {});
    }
    if (videos.isEmpty) _searchRecursive(data, videos, 0);
    return videos;
  }

  static void _searchRecursive(dynamic obj, List<YouTubeVideo> out, int depth) {
    if (depth > 10 || out.length > 100) return;
    if (obj is Map) {
      for (final k in ['videoRenderer', 'reelItemRenderer', 'compactVideoRenderer']) {
        if (obj.containsKey(k)) out.add(_parseVideo(obj[k] as Map));
      }
      for (final v in obj.values) _searchRecursive(v, out, depth + 1);
    } else if (obj is List) {
      for (final item in obj) _searchRecursive(item, out, depth + 1);
    }
  }

  // ─── API ────────────────────────────────────────────────────────

  static Future<List<YouTubeVideo>> getHome({int limit = 24}) async {
    final data = await _loadUrl('$_ytOrigin/');
    if (data == null) return [];
    return _extractVideos(data).take(limit).toList();
  }

  static Future<List<YouTubeVideo>> getSubscriptions({int limit = 30}) async {
    final data = await _loadUrl('$_ytOrigin/feed/subscriptions');
    if (data == null) throw Exception('AUTH_ERROR_401');
    return _extractVideos(data).take(limit).toList();
  }

  static Future<List<YouTubeVideo>> getShorts({int limit = 20}) async {
    final data = await _loadUrl('$_ytOrigin/shorts/');
    if (data == null) return [];
    return _extractVideos(data).take(limit).toList();
  }
}

extension _Let<T> on T {
  R? let<R>(R Function(T it) fn) => fn(this);
}
