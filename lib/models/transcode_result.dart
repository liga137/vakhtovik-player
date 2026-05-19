/// Модель результата транскодирования
class TranscodeResult {
  final String sessionId;
  final String playlistUrl;
  final String quality;

  const TranscodeResult({
    required this.sessionId,
    required this.playlistUrl,
    required this.quality,
  });

  factory TranscodeResult.fromJson(Map<String, dynamic> json) {
    return TranscodeResult(
      sessionId: json['session_id'] as String,
      playlistUrl: json['playlist_url'] as String,
      quality: json['quality'] as String? ?? '360p',
    );
  }
}
