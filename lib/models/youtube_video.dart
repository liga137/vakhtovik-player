class YouTubeVideo {
  final String id;
  final String title;
  final String channel;
  final String viewsText;
  final String publishedText;
  final int duration;
  final String thumbnail;
  final String url;

  const YouTubeVideo({
    required this.id,
    required this.title,
    required this.channel,
    this.viewsText = '',
    this.publishedText = '',
    required this.duration,
    required this.thumbnail,
    required this.url,
  });

  factory YouTubeVideo.fromJson(Map<String, dynamic> json) {
    final id = _cleanText(_firstNonEmpty([
      _readString(json, 'id'),
      _readString(json, 'video_id'),
      _readString(json, 'videoId'),
      _readString(json, 'ytid'),
      _readNestedString(json, 'entry', 'id'),
    ]));
    final rawTitle = _firstNonEmpty([
      _readString(json, 'title'),
      _readString(json, 'name'),
      _readString(json, 'video_title'),
      _readString(json, 'fulltitle'),
      _readString(json, 'original_title'),
      _readNestedString(json, 'videoDetails', 'title'),
      _readNestedString(json, 'entry', 'title'),
      _readNestedString(json, 'snippet', 'title'),
    ]);
    final channel = _cleanText(_firstNonEmpty([
      _readString(json, 'channel'),
      _readString(json, 'author'),
      _readString(json, 'uploader'),
      _readString(json, 'channel_name'),
      _readString(json, 'ownerText'),
      _readNestedString(json, 'snippet', 'channelTitle'),
      _readNestedString(json, 'entry', 'author'),
      _readNestedString(json, 'metadata', 'channel'),
    ]));
    final viewsText = _cleanText(_firstNonEmpty([
      _readString(json, 'views'),
      _readString(json, 'views_text'),
      _readString(json, 'view_count_text'),
      _readString(json, 'short_view_count'),
      _readString(json, 'viewCountText'),
      _readString(json, 'shortViewCountText'),
      _readNestedString(json, 'snippet', 'viewCountText'),
      _readNestedString(json, 'metadata', 'views'),
    ]));
    final publishedText = _cleanText(_firstNonEmpty([
      _readString(json, 'published'),
      _readString(json, 'published_text'),
      _readString(json, 'published_time'),
      _readString(json, 'publishedTimeText'),
      _readNestedString(json, 'snippet', 'publishedAt'),
      _readNestedString(json, 'snippet', 'publishedTimeText'),
      _readNestedString(json, 'metadata', 'published'),
      _readNestedString(json, 'metadata', 'published_at'),
    ]));
    final thumbnail = _extractThumbnail(json);
    final url = _cleanText(_firstNonEmpty([
      _readString(json, 'url'),
      id.isNotEmpty ? 'https://www.youtube.com/watch?v=$id' : '',
    ]));
    final normalizedId = id.isNotEmpty ? id : _extractVideoIdFromUrl(url);
    final title = _cleanText(rawTitle);

    return YouTubeVideo(
      id: normalizedId,
      title: title.isNotEmpty
          ? title
          : _fallbackTitle(
              id: normalizedId,
              channel: channel,
              url: url,
            ),
      channel: channel,
      viewsText: viewsText,
      publishedText: publishedText,
      duration: _toInt(json['duration']),
      thumbnail: thumbnail,
      url: url,
    );
  }

  static int _toInt(dynamic value) {
    if (value is int) return value;
    if (value is double) return value.round();
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }

  static String _readString(Map<String, dynamic> json, String key) {
    return _extractTextValue(json[key]);
  }

  static String _readNestedString(
      Map<String, dynamic> json, String parent, String key) {
    final parentValue = json[parent];
    if (parentValue is! Map) return '';
    return _extractTextValue(parentValue[key]);
  }

  static String _extractTextValue(dynamic value) {
    if (value == null) return '';
    if (value is String) return value.trim();
    if (value is num || value is bool) return value.toString().trim();
    if (value is Map) {
      final simple = _extractTextValue(value['simpleText']);
      if (simple.isNotEmpty) return simple;
      final text = _extractTextValue(value['text']);
      if (text.isNotEmpty) return text;
      final content = _extractTextValue(value['content']);
      if (content.isNotEmpty) return content;
      final title = _extractTextValue(value['title']);
      if (title.isNotEmpty) return title;
      final label = _extractTextValue(value['label']);
      if (label.isNotEmpty) return label;
      final runs = value['runs'];
      if (runs is List) {
        final chunks = <String>[];
        for (final it in runs) {
          if (it is Map) {
            final chunk = _extractTextValue(it['text']);
            if (chunk.isNotEmpty) chunks.add(chunk);
          }
        }
        if (chunks.isNotEmpty) return chunks.join();
      }
      return '';
    }
    if (value is List) {
      for (final it in value) {
        final t = _extractTextValue(it);
        if (t.isNotEmpty) return t;
      }
      return '';
    }
    return value.toString().trim();
  }

  static String _firstNonEmpty(List<String> values) {
    for (final v in values) {
      final t = _cleanText(v);
      if (t.isNotEmpty) return t;
    }
    return '';
  }

  static String _cleanText(String input) {
    final t = input.trim();
    if (t.isEmpty) return '';
    final bad = t.toLowerCase();
    if (bad == 'null' || bad == 'none' || bad == 'undefined' || bad == 'nan') {
      return '';
    }
    if (t == '{}' || t == '[]') return '';
    return t;
  }

  static String _extractVideoIdFromUrl(String url) {
    if (url.isEmpty) return '';
    final uri = Uri.tryParse(url);
    if (uri == null) return '';
    final v = (uri.queryParameters['v'] ?? '').trim();
    if (v.isNotEmpty) return v;
    final parts = uri.pathSegments;
    if (parts.length >= 2 && parts.first == 'shorts') return parts[1].trim();
    if (parts.isNotEmpty && parts.first == 'watch') {
      return (uri.queryParameters['v'] ?? '').trim();
    }
    return '';
  }

  static String _fallbackTitle({
    required String id,
    required String channel,
    required String url,
  }) {
    if (channel.isNotEmpty && id.isNotEmpty) return '$channel · $id';
    if (id.isNotEmpty) return 'Видео $id';
    if (url.isNotEmpty) {
      final uri = Uri.tryParse(url);
      if (uri != null && uri.host.isNotEmpty) {
        return 'Видео с ${uri.host}';
      }
    }
    return 'Без названия';
  }

  static String _extractThumbnail(Map<String, dynamic> json) {
    final direct = _readString(json, 'thumbnail');
    if (direct.isNotEmpty) return direct;
    final thumbSingle = _readString(json, 'thumbnail_url');
    if (thumbSingle.isNotEmpty) return thumbSingle;

    final thumbs = json['thumbnails'];
    if (thumbs is List) {
      for (final item in thumbs) {
        if (item is Map) {
          final url = (item['url'] ?? '').toString().trim();
          if (url.isNotEmpty) return url;
        }
      }
    }
    if (thumbs is Map) {
      for (final k in ['high', 'medium', 'default']) {
        final v = thumbs[k];
        if (v is Map) {
          final url = (v['url'] ?? '').toString().trim();
          if (url.isNotEmpty) return url;
        }
      }
    }
    return '';
  }
}
