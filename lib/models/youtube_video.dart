class YouTubeVideo {
  final String id;
  final String title;
  final String channel;
  final int duration;
  final String thumbnail;
  final String url;

  const YouTubeVideo({
    required this.id,
    required this.title,
    required this.channel,
    required this.duration,
    required this.thumbnail,
    required this.url,
  });

  factory YouTubeVideo.fromJson(Map<String, dynamic> json) {
    final id = _firstNonEmpty([
      _readString(json, 'id'),
      _readString(json, 'video_id'),
      _readString(json, 'videoId'),
      _readString(json, 'ytid'),
    ]);
    final title = _firstNonEmpty([
      _readString(json, 'title'),
      _readString(json, 'name'),
      _readString(json, 'video_title'),
      _readNestedString(json, 'snippet', 'title'),
    ]);
    final channel = _firstNonEmpty([
      _readString(json, 'channel'),
      _readString(json, 'author'),
      _readString(json, 'uploader'),
      _readNestedString(json, 'snippet', 'channelTitle'),
    ]);
    final thumbnail = _extractThumbnail(json);
    final url = _firstNonEmpty([
      _readString(json, 'url'),
      id.isNotEmpty ? 'https://www.youtube.com/watch?v=$id' : '',
    ]);

    return YouTubeVideo(
      id: id,
      title: title.isNotEmpty ? title : 'Без названия',
      channel: channel,
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
    final value = json[key];
    if (value == null) return '';
    return value.toString().trim();
  }

  static String _readNestedString(Map<String, dynamic> json, String parent, String key) {
    final parentValue = json[parent];
    if (parentValue is! Map) return '';
    final value = parentValue[key];
    if (value == null) return '';
    return value.toString().trim();
  }

  static String _firstNonEmpty(List<String> values) {
    for (final v in values) {
      final t = v.trim();
      if (t.isNotEmpty) return t;
    }
    return '';
  }

  static String _extractThumbnail(Map<String, dynamic> json) {
    final direct = _readString(json, 'thumbnail');
    if (direct.isNotEmpty) return direct;

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
