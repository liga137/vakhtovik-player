import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import '../services/api_service.dart';
import '../services/series_parser.dart';

/// Экран плеера: мультиплатформенный HLS стриминг (MediaKit)
class PlayerScreen extends StatefulWidget {
  final String hlsUrl;
  final String sessionId;
  final String? sourceUrl;
  final String quality;
  final String referer;
  final double duration;

  /// Эпизоды сериала (если это сериал)
  final List<SeriesEpisode>? episodes;
  final int currentEpisodeIndex;
  /// Callback: пользователь хочет сменить эпизод
  final void Function(int newIndex)? onEpisodeChange;

  const PlayerScreen({
    super.key,
    required this.hlsUrl,
    required this.sessionId,
    this.sourceUrl,
    this.quality = '240p',
    this.referer = '',
    this.duration = 0,
    this.episodes,
    this.currentEpisodeIndex = 0,
    this.onEpisodeChange,
  });

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  late final player = Player();
  late final controller = VideoController(player);
  
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

  @override
  void initState() {
    super.initState();
    _durationHintSeconds = widget.duration;
    _initPlayer();
    _startDurationProbe();
    
    player.stream.error.listen((error) {
      if (error != 'none') _onPlaybackError(error.toString());
    });

    // Авто-следующая серия при завершении видео
    player.stream.completed.listen((_) {
      _onVideoCompleted();
    });
  }

  void _onVideoCompleted() {
    if (widget.episodes == null || widget.onEpisodeChange == null) return;
    final nextIndex = widget.currentEpisodeIndex + 1;
    if (nextIndex < widget.episodes!.length) {
      widget.onEpisodeChange!(nextIndex);
    }
  }

  Future<void> _initPlayer() async {
    try {
      await player.open(Media(widget.hlsUrl), play: true);
    } catch (e) {
      _onPlaybackError('Ошибка инициализации плеера: $e');
      return;
    }

    if (mounted) {
      setState(() {
        _isInitialized = true;
        _reconnecting = false;
        _reconnectStatus = null;
        _reconnectAttempts = 0;
      });
    }
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
    _durationTimer?.cancel();
    _hideTimer?.cancel();
    ApiService.stopSession(widget.sessionId).catchError((_) {});
    player.dispose();
    super.dispose();
  }

  // ── Авто-скрытие AppBar / оверлея ─────────────────────────
  bool _controlsVisible = true;
  Timer? _hideTimer;
  static const Duration _hideDelay = Duration(seconds: 3);

  void _onMouseMove() {
    if (!mounted) return;
    if (!_controlsVisible) {
      setState(() => _controlsVisible = true);
    }
    _hideTimer?.cancel();
    _hideTimer = Timer(_hideDelay, () {
      if (mounted) setState(() => _controlsVisible = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final dur = _fmtDuration(
        _durationHintSeconds > 0 ? _durationHintSeconds : widget.duration);

    final hasEpisodes =
        widget.episodes != null && widget.episodes!.isNotEmpty;
    final totalEpisodes = widget.episodes?.length ?? 0;
    final currentEp = widget.currentEpisodeIndex >= 0 &&
            widget.currentEpisodeIndex < totalEpisodes
        ? widget.episodes![widget.currentEpisodeIndex]
        : null;
    final epLabel = currentEp != null
        ? '${currentEp.displayNumber} / $totalEpisodes'
        : '';

    return MouseRegion(
      onHover: (_) => _onMouseMove(),
      onEnter: (_) => _onMouseMove(),
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Stack(
          fit: StackFit.expand,
          children: [
            // Видео — всегда на весь экран
            if (_isInitialized)
              Video(controller: controller)
            else
              Center(
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

            // Верхняя панель (AppBar)
            AnimatedPositioned(
              duration: const Duration(milliseconds: 300),
              curve: Curves.easeInOut,
              top: _controlsVisible ? 0 : -80,
              left: 0,
              right: 0,
              child: Container(
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Color(0xCC000000), Colors.transparent],
                  ),
                ),
                padding: EdgeInsets.only(
                    top: MediaQuery.of(context).padding.top + 4,
                    bottom: 12,
                    left: 4,
                    right: 4),
                child: Row(
                  children: [
                    IconButton(
                      icon: const Icon(Icons.close, color: Colors.white),
                      tooltip: 'Закрыть плеер',
                      onPressed: () {
                        ApiService.stopSession(widget.sessionId);
                        if (mounted) Navigator.pop(context);
                      },
                    ),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(dur.isNotEmpty ? 'Плеер · $dur' : 'Плеер',
                              style: const TextStyle(
                                  color: Colors.white, fontSize: 14)),
                          if (epLabel.isNotEmpty)
                            Text(epLabel,
                                style: const TextStyle(
                                    fontSize: 11,
                                    color: Colors.orange,
                                    height: 1.1)),
                        ],
                      ),
                    ),
                    // Навигация по эпизодам
                    if (hasEpisodes && widget.currentEpisodeIndex > 0)
                      IconButton(
                        icon: const Icon(Icons.skip_previous,
                            size: 22, color: Colors.white70),
                        tooltip: 'Предыдущая серия',
                        onPressed: () => widget.onEpisodeChange
                            ?.call(widget.currentEpisodeIndex - 1),
                      ),
                    if (hasEpisodes &&
                        widget.currentEpisodeIndex < totalEpisodes - 1)
                      IconButton(
                        icon: const Icon(Icons.skip_next,
                            size: 22, color: Colors.white70),
                        tooltip: 'Следующая серия',
                        onPressed: () => widget.onEpisodeChange
                            ?.call(widget.currentEpisodeIndex + 1),
                      ),
                    // Качество
                    if (widget.sourceUrl != null)
                      PopupMenuButton<String>(
                        tooltip: 'Качество',
                        initialValue: widget.quality,
                        onSelected: _switchQuality,
                        icon: const Icon(Icons.settings,
                            color: Colors.orange, size: 20),
                        itemBuilder: (_) => const [
                          PopupMenuItem(value: '144p', child: Text('144p')),
                          PopupMenuItem(value: '240p', child: Text('240p')),
                          PopupMenuItem(value: '360p', child: Text('360p')),
                          PopupMenuItem(value: '480p', child: Text('480p')),
                        ],
                      ),
                    // Скачать
                    IconButton(
                      icon: _isDownloading
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2, color: Colors.orange),
                            )
                          : const Icon(Icons.download,
                              color: Colors.white70, size: 20),
                      tooltip: 'Скачать mp4',
                      onPressed:
                          _isDownloading ? null : _downloadCurrentSession,
                    ),
                  ],
                ),
              ),
            ),

            // Нижний оверлей с прогресс-баром
            if (_isInitialized)
              AnimatedPositioned(
                duration: const Duration(milliseconds: 300),
                curve: Curves.easeInOut,
                bottom: _controlsVisible ? 0 : -60,
                left: 0,
                right: 0,
                child: Container(
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.bottomCenter,
                      end: Alignment.topCenter,
                      colors: [Color(0xCC000000), Colors.transparent],
                    ),
                  ),
                  padding: const EdgeInsets.only(
                      bottom: 16, top: 16, left: 16, right: 16),
                  child: Row(
                    children: [
                      // Play/Pause
                      Material(
                        color: Colors.transparent,
                        child: InkWell(
                          onTap: () {
                            if (player.state.playing) {
                              player.pause();
                            } else {
                              player.play();
                            }
                            setState(() {}); // trigger rebuild for icon
                          },
                          child: StreamBuilder<bool>(
                            stream: player.stream.playing,
                            initialData: player.state.playing,
                            builder: (_, snap) => Icon(
                              snap.data == true
                                  ? Icons.pause
                                  : Icons.play_arrow,
                              color: Colors.white,
                              size: 28,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      // Прогресс
                      Expanded(
                        child: StreamBuilder<Duration>(
                          stream: player.stream.position,
                          initialData: player.state.position,
                          builder: (_, posSnap) {
                            final pos = posSnap.data ?? Duration.zero;
                            final total = _durationHintSeconds > 0
                                ? Duration(
                                    milliseconds:
                                        (_durationHintSeconds * 1000).round())
                                : player.state.duration;
                            final posPercent = total.inMilliseconds > 0
                                ? pos.inMilliseconds / total.inMilliseconds
                                : 0.0;
                            return Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                // Полоса прогресса
                                GestureDetector(
                                  onTapDown: (d) {
                                    final box = context.findRenderObject()
                                        as RenderBox;
                                    final localX = d.localPosition.dx;
                                    final ratio = (localX / box.size.width)
                                        .clamp(0.0, 1.0);
                                    final seekMs =
                                        (ratio * total.inMilliseconds).round();
                                    player.seek(
                                        Duration(milliseconds: seekMs));
                                  },
                                  child: Container(
                                    height: 4,
                                    decoration: BoxDecoration(
                                      color: Colors.white24,
                                      borderRadius:
                                          BorderRadius.circular(2),
                                    ),
                                    child: FractionallySizedBox(
                                      alignment: Alignment.centerLeft,
                                      widthFactor:
                                          posPercent.clamp(0.0, 1.0),
                                      child: Container(
                                        decoration: BoxDecoration(
                                          color: Colors.orange,
                                          borderRadius:
                                              BorderRadius.circular(2),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 4),
                                // Время
                                Row(
                                  mainAxisAlignment:
                                      MainAxisAlignment.spaceBetween,
                                  children: [
                                    Text(_fmtDuration(
                                        pos.inMilliseconds / 1000),
                                        style: const TextStyle(
                                            color: Colors.white70,
                                            fontSize: 10)),
                                    Text(
                                        _fmtDuration(
                                            total.inMilliseconds / 1000),
                                        style: const TextStyle(
                                            color: Colors.white70,
                                            fontSize: 10)),
                                  ],
                                ),
                              ],
                            );
                          },
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
