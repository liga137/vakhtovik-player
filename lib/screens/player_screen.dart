import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import 'package:chewie/chewie.dart';
import 'package:window_manager/window_manager.dart';
import 'dart:async';
import 'dart:convert';
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

class _PlayerScreenState extends State<PlayerScreen> with WidgetsBindingObserver, WindowListener {
  VideoPlayerController? _controller;
  ChewieController? _chewieController;
  bool _isInitialized = false;
  bool _isDownloading = false;
  double _durationHintSeconds = 0;
  Timer? _durationTimer;
  bool _durationRefreshInFlight = false;

  // -- Сценарий восстановления после обрыва сети (ADR-009) ---
  int _reconnectAttempts = 0;
  static const int _maxReconnectAttempts = 3;
  static const Duration _reconnectDelay = Duration(seconds: 5);
  bool _reconnecting = false;
  String? _reconnectStatus;
  bool _isWindowHidden = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (Platform.isWindows) windowManager.addListener(this);
    _durationHintSeconds = widget.duration;
    _initPlayer();
    _startDurationProbe();
  }

  Future<void> _initPlayer() async {
    _controller?.removeListener(_onPlayerError);
    _controller?.dispose();
    _chewieController?.dispose();

    _controller = VideoPlayerController.networkUrl(Uri.parse(widget.hlsUrl));
    _controller!.addListener(_onPlayerError);

    try {
      await _controller!.initialize();
    } catch (e) {
      _onPlaybackError('Ошибка инициализации плеера: $e');
      return;
    }

    await Future.delayed(const Duration(milliseconds: 500));
    final ar = _controller!.value.aspectRatio > 0
        ? _controller!.value.aspectRatio
        : 16 / 9;

    _chewieController = ChewieController(
      videoPlayerController: _controller!,
      autoPlay: true,
      looping: false,
      aspectRatio: ar,
      isLive: false,
      allowFullScreen: true,
      allowMuting: true,
      showControls: true,
      showControlsOnInitialize: true,
    );

    if (mounted) {
      setState(() {
        _isInitialized = true;
        _reconnecting = false;
        _reconnectStatus = null;
        _reconnectAttempts = 0;
      });
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!mounted || !Platform.isWindows) return;
    if (state == AppLifecycleState.hidden || state == AppLifecycleState.paused) {
      _hideVideo();
    } else if (state == AppLifecycleState.resumed) {
      _showVideo();
    }
  }

  // window_manager listener (Windows): надёжнее чем AppLifecycle
  @override
  void onWindowMinimize() => _hideVideo();

  @override
  void onWindowRestore() => _showVideo();

  void _hideVideo() {
    if (_isWindowHidden) return;
    setState(() => _isWindowHidden = true);
    // Диспоузим Chewie — текстура освобождается
    _chewieController?.dispose();
    _chewieController = null;
    // Паузим видео (контроллер остаётся, но текстуры нет)
    _controller?.pause();
  }

  void _showVideo() {
    if (!_isWindowHidden) return;
    setState(() => _isWindowHidden = false);
    // Пересоздаём Chewie на том же контроллере
    if (_controller != null && _controller!.value.isInitialized) {
      _controller!.play();
      _chewieController = ChewieController(
        videoPlayerController: _controller!,
        autoPlay: true,
        looping: false,
        aspectRatio: _controller!.value.aspectRatio > 0
            ? _controller!.value.aspectRatio
            : 16 / 9,
        allowFullScreen: true,
        allowMuting: true,
        showControls: true,
        showControlsOnInitialize: true,
      );
      // Принудительно обновляем UI
      if (mounted) setState(() {});
    }
  }

  void _onPlayerError() {
    if (_controller == null || _reconnecting) return;
    final err = _controller!.value.errorDescription;
    if (err == null || err.isEmpty) return;
    _onPlaybackError(err);
  }

  void _onPlaybackError(String reason) {
    if (_reconnecting || !mounted) return;
    if (_reconnectAttempts >= _maxReconnectAttempts) {
      setState(() {
        _reconnectStatus = 'Не удалось восстановить видео после '
            '$_maxReconnectAttempts попыток.\n$reason';
      });
      return;
    }

    setState(() {
      _reconnecting = true;
      _reconnectAttempts++;
      _isInitialized = false;
      _reconnectStatus = 'Обрыв сети. Попытка $_reconnectAttempts '
          'из $_maxReconnectAttempts...';
    });

    Future<void>.delayed(_reconnectDelay, () {
      if (!mounted) return;
      _initPlayer();
    });
  }

  void _startDurationProbe() {
    _durationTimer?.cancel();
    _durationTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      _refreshDurationHint();
    });
    unawaited(_refreshDurationHint());
  }

  Future<double> _readPlaylistDurationSeconds() async {
    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 15);
    client.badCertificateCallback = (_, __, ___) => true;
    if (Platform.isWindows) {
      client.findProxy = (uri) => 'PROXY 127.0.0.1:1080; DIRECT';
    }
    try {
      final req = await client.getUrl(Uri.parse(widget.hlsUrl));
      final resp = await req.close().timeout(const Duration(seconds: 10));
      if (resp.statusCode != 200) return 0;
      final body = await utf8.decoder.bind(resp).join();
      final re = RegExp(r'#EXTINF:([0-9]*\.?[0-9]+)');
      var total = 0.0;
      for (final m in re.allMatches(body)) {
        total += double.tryParse(m.group(1) ?? '') ?? 0;
      }
      return total;
    } catch (_) {
      return 0;
    } finally {
      client.close(force: true);
    }
  }

  double _extractDurationFromStatus(Map<String, dynamic> status) {
    final keys = [
      'duration',
      'duration_sec',
      'duration_seconds',
      'total_duration',
      'media_duration',
    ];
    for (final key in keys) {
      final raw = status[key];
      if (raw is num && raw > 0) return raw.toDouble();
      final parsed = double.tryParse('${raw ?? ''}') ?? 0;
      if (parsed > 0) return parsed;
    }
    return 0;
  }

  Future<void> _refreshDurationHint() async {
    if (_durationRefreshInFlight) return;
    _durationRefreshInFlight = true;
    try {
      final status = await ApiService.getStatus(widget.sessionId)
          .timeout(const Duration(seconds: 8));
      final fromStatus = _extractDurationFromStatus(status);
      final fromPlaylist = await _readPlaylistDurationSeconds();
      final best = [
        widget.duration,
        _durationHintSeconds,
        fromStatus,
        fromPlaylist
      ].fold<double>(0, (prev, e) => e > prev ? e : prev);
      if (!mounted) return;
      if (best > _durationHintSeconds + 0.3) {
        setState(() => _durationHintSeconds = best);
      }
    } catch (_) {
      // Тихий фоновый опрос: не шумим пользователю.
    } finally {
      _durationRefreshInFlight = false;
    }
  }

  Future<void> _switchQuality(String newQuality) async {
    final source = widget.sourceUrl;
    if (source == null || source.isEmpty || newQuality == widget.quality) {
      return;
    }

    // Закрываем текущий и открываем новый плеер — без гонки
    ApiService.stopSession(widget.sessionId).catchError((_) {});
    final result = await ApiService.transcode(
        url: source, quality: newQuality, referer: widget.referer);
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
    if (h > 0) {
      return '$h:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
    }
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
        SnackBar(
            content: Text('Скачано: $outputPath'),
            duration: const Duration(seconds: 4)),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text('Ошибка скачивания: $e'),
            duration: const Duration(seconds: 4)),
      );
    } finally {
      if (mounted) setState(() => _isDownloading = false);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (Platform.isWindows) windowManager.removeListener(this);
    _durationTimer?.cancel();
    ApiService.stopSession(widget.sessionId).catchError((_) {});
    _chewieController?.dispose();
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final dur = _fmtDuration(
        _durationHintSeconds > 0 ? _durationHintSeconds : widget.duration);
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
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.orange),
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
      body: _isInitialized && _chewieController != null && !_isWindowHidden
          ? Chewie(controller: _chewieController!)
          : _isWindowHidden
              ? Container(color: Colors.black)
              : Center(
              child: Container(
                color: Colors.black54,
                child: Center(
                  child: Container(
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(
                        color: const Color(0xCC1A0F08),
                        borderRadius: BorderRadius.circular(16)),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (_reconnectAttempts >= _maxReconnectAttempts &&
                            _reconnectStatus != null)
                          const Icon(Icons.error_outline,
                              color: Colors.orange, size: 36),
                        if (_reconnectAttempts < _maxReconnectAttempts ||
                            _reconnectStatus == null)
                          const CircularProgressIndicator(
                              color: Colors.orange),
                        const SizedBox(height: 14),
                        Text(
                          _reconnectStatus ?? 'Запускаю ${widget.quality}...',
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                              color: Colors.white, fontSize: 16),
                        ),
                        if (_reconnectAttempts >= _maxReconnectAttempts) ...[
                          const SizedBox(height: 12),
                          ElevatedButton(
                            style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.orange),
                            onPressed: () {
                              setState(() {
                                _reconnectAttempts = 0;
                                _reconnectStatus = null;
                              });
                              _initPlayer();
                            },
                            child: const Text('Попробовать снова',
                                style: TextStyle(color: Colors.black)),
                          ),
                          const SizedBox(height: 6),
                          TextButton(
                            onPressed: () {
                              if (mounted) Navigator.pop(context);
                            },
                            child: const Text('Выйти',
                                style: TextStyle(color: Colors.white54)),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ),
    );
  }
}
