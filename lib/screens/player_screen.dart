import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import 'package:chewie/chewie.dart';
import 'dart:async';
import 'dart:io';
import '../services/api_service.dart';

/// Экран плеера: мультиплатформенный HLS стриминг
class PlayerScreen extends StatefulWidget {
  final String hlsUrl;
  final String sessionId;
  final String? sourceUrl;
  final String quality;
  final String referer;
  final double duration;

  const PlayerScreen({
    super.key,
    required this.hlsUrl,
    required this.sessionId,
    this.sourceUrl,
    this.quality = '240p',
    this.referer = '',
    this.duration = 0,
  });

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  VideoPlayerController? _controller;
  ChewieController? _chewieController;
  bool _isInitialized = false;
  bool _isDownloading = false;

  @override
  void initState() {
    super.initState();
    _initPlayer();
  }

  Future<void> _initPlayer() async {
    _controller = VideoPlayerController.networkUrl(Uri.parse(widget.hlsUrl));
    await _controller!.initialize();

    await Future.delayed(const Duration(milliseconds: 500));
    final ar = _controller!.value.aspectRatio > 0 ? _controller!.value.aspectRatio : 16 / 9;

    _chewieController = ChewieController(
      videoPlayerController: _controller!,
      autoPlay: true,
      looping: false,
      aspectRatio: ar,
      isLive: widget.duration <= 0,
      allowFullScreen: true,
      allowMuting: true,
      showControls: true,
      showControlsOnInitialize: true,
    );

    if (mounted) {
      setState(() => _isInitialized = true);
    }
  }

  Future<void> _switchQuality(String newQuality) async {
    final source = widget.sourceUrl;
    if (source == null || source.isEmpty || newQuality == widget.quality) return;

    // Закрываем текущий и открываем новый плеер — без гонки
    ApiService.stopSession(widget.sessionId).catchError((_) {});
    final result = await ApiService.transcode(url: source, quality: newQuality, referer: widget.referer);
    if (!mounted) return;

    Navigator.of(context).pushReplacement(MaterialPageRoute(
      builder: (_) => PlayerScreen(
        hlsUrl: ApiService.hlsUrl(result.playlistUrl),
        sessionId: result.sessionId,
        sourceUrl: source,
        quality: newQuality,
        referer: widget.referer,
        duration: widget.duration,
      ),
    ));
  }

  String _fmtDuration(double seconds) {
    if (seconds <= 0) return '';
    final d = seconds.round();
    final h = d ~/ 3600;
    final m = (d % 3600) ~/ 60;
    final s = d % 60;
    if (h > 0) return '$h:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  Future<Directory> _resolveDownloadDirectory() async {
    if (Platform.isWindows) {
      final userProfile = Platform.environment['USERPROFILE'];
      if (userProfile != null && userProfile.isNotEmpty) {
        final d = Directory('$userProfile\\Downloads');
        if (await d.exists()) return d;
      }
    }
    if (Platform.isAndroid) {
      final d = Directory('/storage/emulated/0/Download');
      if (await d.exists()) return d;
    }
    return Directory.systemTemp;
  }

  Future<void> _downloadCurrentSession() async {
    if (_isDownloading) return;
    setState(() => _isDownloading = true);
    try {
      final dir = await _resolveDownloadDirectory();
      final filename = 'vakhtovik_${widget.sessionId}_${widget.quality}.mp4';
      final outputPath = '${dir.path}${Platform.pathSeparator}$filename';
      await ApiService.downloadSessionMp4(
        sessionId: widget.sessionId,
        outputPath: outputPath,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Скачано: $outputPath'), duration: const Duration(seconds: 4)),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Ошибка скачивания: $e'), duration: const Duration(seconds: 4)),
      );
    } finally {
      if (mounted) setState(() => _isDownloading = false);
    }
  }

  @override
  void dispose() {
    ApiService.stopSession(widget.sessionId).catchError((_) {});
    _chewieController?.dispose();
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final dur = _fmtDuration(widget.duration);
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: Text(dur.isNotEmpty ? 'Плеер · $dur' : 'Плеер'),
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        actions: [
          if (widget.sourceUrl != null)
            PopupMenuButton<String>(
              tooltip: 'Качество',
              initialValue: widget.quality,
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
            icon: _isDownloading
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.orange),
                  )
                : const Icon(Icons.download),
            tooltip: 'Скачать mp4',
            onPressed: _isDownloading ? null : _downloadCurrentSession,
          ),
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
        child: _isInitialized && _chewieController != null
            ? Stack(
                children: [
                  Positioned.fill(child: Chewie(controller: _chewieController!)),
                  Positioned(
                    left: 12,
                    right: 12,
                    top: 10,
                    child: IgnorePointer(
                      child: _PlaybackStatusOverlay(
                        controller: _controller!,
                        fallbackDurationSeconds: widget.duration,
                      ),
                    ),
                  ),
                ],
              )
            : Container(
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
                        Text('Запускаю ${widget.quality}...', style: const TextStyle(color: Colors.white, fontSize: 16)),
                      ],
                    ),
                  ),
                ),
              ),
      ),
    );
  }
}

class _PlaybackStatusOverlay extends StatefulWidget {
  final VideoPlayerController controller;
  final double fallbackDurationSeconds;

  const _PlaybackStatusOverlay({
    required this.controller,
    required this.fallbackDurationSeconds,
  });

  @override
  State<_PlaybackStatusOverlay> createState() => _PlaybackStatusOverlayState();
}

class _PlaybackStatusOverlayState extends State<_PlaybackStatusOverlay> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_tick);
    _timer = Timer.periodic(const Duration(milliseconds: 500), (_) => _tick());
  }

  @override
  void dispose() {
    _timer?.cancel();
    widget.controller.removeListener(_tick);
    super.dispose();
  }

  void _tick() {
    if (mounted) setState(() {});
  }

  String _fmt(Duration d) {
    if (d.inMilliseconds <= 0) return '0:00';
    final h = d.inHours;
    final m = d.inMinutes.remainder(60);
    final s = d.inSeconds.remainder(60);
    if (h > 0) {
      return '$h:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
    }
    return '${d.inMinutes}:${s.toString().padLeft(2, '0')}';
  }

  Duration _effectiveDuration(VideoPlayerValue v) {
    final duration = v.duration;
    if (duration.inMilliseconds > 0) return duration;
    final fallbackMs = (widget.fallbackDurationSeconds * 1000).round();
    if (fallbackMs > 0) return Duration(milliseconds: fallbackMs);
    return Duration.zero;
  }

  @override
  Widget build(BuildContext context) {
    final value = widget.controller.value;
    final position = value.position;
    final duration = _effectiveDuration(value);
    final bufferedEnd = value.buffered.isNotEmpty ? value.buffered.last.end : Duration.zero;

    final totalMs = duration.inMilliseconds;
    final posMs = position.inMilliseconds.clamp(0, totalMs > 0 ? totalMs : position.inMilliseconds).toDouble();
    final bufMs = bufferedEnd.inMilliseconds.clamp(0, totalMs > 0 ? totalMs : bufferedEnd.inMilliseconds).toDouble();

    final progress = totalMs > 0 ? (posMs / totalMs).clamp(0.0, 1.0).toDouble() : 0.0;
    final bufferProgress = totalMs > 0 ? (bufMs / totalMs).clamp(0.0, 1.0).toDouble() : 0.0;
    final bufferedAhead = bufferedEnd - position;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xCC000000),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.white24),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              const Icon(Icons.schedule, color: Colors.orange, size: 14),
              const SizedBox(width: 6),
              Text(
                '${_fmt(position)} / ${totalMs > 0 ? _fmt(duration) : 'длит. не определена'}',
                style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600),
              ),
              const Spacer(),
              if (value.isBuffering)
                const SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.orange),
                ),
              const SizedBox(width: 8),
              Text(
                bufferedAhead.inSeconds > 0 ? 'Буфер +${bufferedAhead.inSeconds}с' : 'Буфер 0с',
                style: const TextStyle(color: Colors.white70, fontSize: 11),
              ),
            ],
          ),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: SizedBox(
              height: 4,
              child: Stack(
                children: [
                  Positioned.fill(child: Container(color: Colors.white12)),
                  FractionallySizedBox(
                    widthFactor: bufferProgress,
                    child: Container(color: Colors.white38),
                  ),
                  FractionallySizedBox(
                    widthFactor: progress,
                    child: Container(color: Colors.orange),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
