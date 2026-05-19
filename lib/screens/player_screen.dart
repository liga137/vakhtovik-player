import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import '../services/api_service.dart';

/// Экран плеера: мультиплатформенный HLS стриминг
class PlayerScreen extends StatefulWidget {
  final String hlsUrl;
  final String sessionId;

  const PlayerScreen({
    super.key,
    required this.hlsUrl,
    required this.sessionId,
  });

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  late final Player player;
  late final VideoController controller;

  @override
  void initState() {
    super.initState();
    // Инициализация мощного движка
    player = Player(
      configuration: const PlayerConfiguration(
        bufferSize: 32 * 1024 * 1024, // 32 MB буфер для HLS
      ),
    );
    controller = VideoController(player);

    // Запуск стрима
    player.open(Media(widget.hlsUrl));
  }

  @override
  void dispose() {
    // 1. Убиваем сессию на сервере (Garbage Collector)
    ApiService.stopSession(widget.sessionId).catchError((_) {});
    // 2. Освобождаем память плеера
    player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text('Плеер'),
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            icon: const Icon(Icons.stop),
            tooltip: 'Остановить транскодирование',
            onPressed: () {
              ApiService.stopSession(widget.sessionId);
              if (mounted) Navigator.pop(context);
            },
          ),
        ],
      ),
      body: Center(
        child: Video(
          controller: controller,
          controls: AdaptiveVideoControls, // Авто-UI для ПК и сенсора
        ),
      ),
    );
  }
}
