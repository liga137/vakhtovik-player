/// Модель пресета качества
class Preset {
  final String id;
  final String label;
  final int width;
  final int crf;
  final String audioBitrate;

  const Preset({
    required this.id,
    required this.label,
    required this.width,
    required this.crf,
    required this.audioBitrate,
  });

  factory Preset.fromJson(String id, Map<String, dynamic> json) {
    return Preset(
      id: id,
      label: json['label'] as String? ?? id,
      width: json['width'] as int? ?? 640,
      crf: json['crf'] as int? ?? 32,
      audioBitrate: json['audio_bitrate'] as String? ?? '32k',
    );
  }
}
