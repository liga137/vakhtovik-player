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
    final id = (json['id'] ?? '').toString();
    return YouTubeVideo(
      id: id,
      title: (json['title'] ?? 'Без названия').toString(),
      channel: (json['channel'] ?? '').toString(),
      duration: _toInt(json['duration']),
      thumbnail: (json['thumbnail'] ?? '').toString(),
      url: (json['url'] ?? 'https://www.youtube.com/watch?v=$id').toString(),
    );
  }

  static int _toInt(dynamic value) {
    if (value is int) return value;
    if (value is double) return value.round();
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }
}
