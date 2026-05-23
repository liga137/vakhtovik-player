import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import 'package:chewie/chewie.dart';
import '../services/api_service.dart';

/// Экран плеера: мультиплатформенный HLS стриминг
class PlayerScreen extends StatefulWidget {
  final String hlsUrl;
  final String sessionId;
  final String? sourceUrl;
  final String quality;
  final String referer;

  const PlayerScreen({
    super.key,
    required this.hlsUrl,
    required this.sessionId,
    this.sourceUrl,
    this.quality = '240p',
    this.referer = '',
  });

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  late VideoPlayerController _controller;
  ChewieController? _chewieController;
  bool _isInitialized = false;
  bool _switchingQuality = false;
  late String _hlsUrl;
  late String _sessionId;
  late String _quality;

  @override
  void initState() {
    super.initState();
    _hlsUrl = widget.hlsUrl;
    _sessionId = widget.sessionId;
    _quality = widget.quality;
    _initPlayer();
  }

  Future<void> _initPlayer() async {
    _controller = VideoPlayerController.networkUrl(Uri.parse(_hlsUrl));
    await _controller.initialize();
    
    await Future.delayed(const Duration(milliseconds: 500));
    final ar = _controller.value.aspectRatio > 0 ? _controller.value.aspectRatio : 16 / 9;

    _chewieController = ChewieController(
      videoPlayerController: _controller,
      autoPlay: true,
      looping: false,
      aspectRatio: ar,
      allowFullScreen: true,
      allowMuting: true,
      showControls: true,
      showControlsOnInitialize: true,
    );

    if (mounted) {
      setState(() => _isInitialized = true);
    }
  }

  Future<void> _switchQuality(String quality) async {
    final source = widget.sourceUrl;
    if (source == null || source.isEmpty || quality == _quality || _switchingQuality) return;
    setState(() { _switchingQuality = true; _isInitialized = false; });
    try {
      ApiService.stopSession(_sessionId).catchError((_) {});
      _chewieController?.dispose();
      await _controller.dispose();
      final result = await ApiService.transcode(url: source, quality: quality, referer: widget.referer);
      _hlsUrl = ApiService.hlsUrl(result.playlistUrl);
      _sessionId = result.sessionId;
      _quality = quality;
      await _initPlayer();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Ошибка качества: $e')));
      }
    } finally {
      if (mounted) setState(() => _switchingQuality = false);
    }
  }

  @override
  void dispose() {
    // 1. Убиваем сессию на сервере (Garbage Collector)
    ApiService.stopSession(_sessionId).catchError((_) {});
    // 2. Освобождаем память плеера
    _chewieController?.dispose();
    _controller.dispose();
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
          if (widget.sourceUrl != null)
            PopupMenuButton<String>(
              tooltip: 'Качество',
              initialValue: _quality,
              onSelected: _switchQuality,
              icon: const Icon(Icons.settings, color: Colors.orange),
              itemBuilder: (_) => const [
                PopupMenuItem(value: '144p', child: Text('144p')),
                PopupMenuItem(value: '240p', child: Text('240p')),
                PopupMenuItem(value: '360p', child: Text('360p')),
                PopupMenuItem(value: '480p', child: Text('480p')),
              ],
            ),
          IconButton(
            icon: const Icon(Icons.stop),
            tooltip: 'Остановить транскодирование',
            onPressed: () {
              ApiService.stopSession(_sessionId);
              if (mounted) Navigator.pop(context);
            },
          ),
        ],
      ),
      body: Center(
        child: Stack(
          alignment: Alignment.center,
          children: [
            if (_isInitialized && _chewieController != null) Chewie(controller: _chewieController!),
            if (!_isInitialized || _switchingQuality)
              _BusyOverlay(text: _switchingQuality ? 'Запускаю $_quality...' : 'Загружаю...'),
          ],
        ),
      ),
    );
  }
}

class _BusyOverlay extends StatelessWidget {
  final String text;
  const _BusyOverlay({required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.black54,
      child: Center(
        child: Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(color: const Color(0xCC1A0F08), borderRadius: BorderRadius.circular(16)),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const CircularProgressIndicator(color: Colors.orange),
              const SizedBox(height: 14),
              Text(text, style: const TextStyle(color: Colors.white, fontSize: 16)),
            ],
          ),
        ),
      ),
    );
  }
}
