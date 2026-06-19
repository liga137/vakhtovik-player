import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import '../services/api_service.dart';
import '../services/series_parser.dart';
import '../services/hls_proxy_service.dart';

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
    // Защита от ложных срабатываний (если HLS пустой или транскодер упал)
    if (player.state.position.inSeconds < 10) return;

    if (widget.episodes == null || widget.onEpisodeChange == null) return;
    final nextIndex = widget.currentEpisodeIndex + 1;
    if (nextIndex < widget.episodes!.length) {
      widget.onEpisodeChange!(nextIndex);
    }
  }

  Future<void> _initPlayer() async {
    try {
      String playUrl = widget.hlsUrl;
      
      // Локальный прокси временно отключен из-за проблем с HTTP Range запросами (MediaKit/libmpv)
      // Будет переписан под правильный стриминг.
      // try {
      //   await HlsProxyService.instance.start(widget.hlsUrl);
      //   playUrl = 'http://127.0.0.1:${HlsProxyService.instance.port}/playlist.m3u8';
      // } catch (e) {
      //   print('[PlayerScreen] Failed to start HlsProxy: $e');
      // }

      await player.open(Media(playUrl), play: true);
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

  void _showQualityDialog() {
    showDialog(
      context: context,
      builder: (_) => SimpleDialog(
        title: const Text('Качество', style: TextStyle(color: Colors.white)),
        backgroundColor: const Color(0xFF1A1A1A),
        children: ['144p', '240p', '360p', '480p'].map((q) {
          return SimpleDialogOption(
            onPressed: () {
              Navigator.pop(context);
              _switchQuality(q);
            },
            child: Text(q, style: TextStyle(
              color: q == widget.quality ? Colors.orange : Colors.white70,
              fontWeight: q == widget.quality ? FontWeight.bold : FontWeight.normal,
            )),
          );
        }).toList(),
      ),
    );
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
        episodes: widget.episodes,
        currentEpisodeIndex: widget.currentEpisodeIndex,
        onEpisodeChange: widget.onEpisodeChange,
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
    HlsProxyService.instance.stop();
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
    final dur = _fmtDuration(_durationHintSeconds > 0 ? _durationHintSeconds : widget.duration);
    final hasEpisodes = widget.episodes != null && widget.episodes!.isNotEmpty;
    final totalEpisodes = widget.episodes?.length ?? 0;
    final currentEp = widget.currentEpisodeIndex >= 0 && widget.currentEpisodeIndex < totalEpisodes
        ? widget.episodes![widget.currentEpisodeIndex]
        : null;
    final epLabel = currentEp != null ? '${currentEp.displayNumber} / $totalEpisodes' : '';

    // Уникальные переводы
    final translations = hasEpisodes
        ? widget.episodes!.map((e) => e.translation ?? '').where((t) => t.isNotEmpty).toSet().toList()
        : <String>[];
    final currentTranslation = currentEp?.translation ?? (translations.isNotEmpty ? translations.first : '');
    final filteredEpisodes = hasEpisodes && currentTranslation.isNotEmpty
        ? widget.episodes!.where((e) => (e.translation ?? '') == currentTranslation).toList()
        : (widget.episodes ?? []);

    return MouseRegion(
      onHover: (_) => _onMouseMove(),
      onEnter: (_) => _onMouseMove(),
      child: Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // 1. Видео с РОДНЫМИ контролями MediaKit (нижний бар: пауза/громкость/прогресс)
          if (_isInitialized)
            Video(controller: controller)
          else
            _buildLoadingOverlay(),

          // 2. Наш кастомный верхний бар — поверх видео, НЕ мешает родному низу
          if (_isInitialized)
            Positioned(
              top: 0, left: 0, right: 0,
              child: SafeArea(
                child: AnimatedOpacity(
                  opacity: _controlsVisible ? 1.0 : 0.0,
                  duration: const Duration(milliseconds: 300),
                  child: _buildTopBar(epLabel, hasEpisodes, totalEpisodes,
                      translations, currentTranslation, filteredEpisodes),
                ),
              ),
            ),

          // 3. Кнопка «назад» когда плеер ещё грузится
          if (!_isInitialized)
            Positioned(
              top: MediaQuery.of(context).padding.top + 8, left: 8,
              child: GestureDetector(
                onTap: () { ApiService.stopSession(widget.sessionId); if (mounted) Navigator.pop(context); },
                child: const Padding(padding: EdgeInsets.all(12), child: Icon(Icons.arrow_back, color: Colors.white, size: 22)),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildLoadingOverlay() {
    return Center(
      child: Container(color: Colors.black54, child: Center(
        child: Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(color: const Color(0xCC1A0F08), borderRadius: BorderRadius.circular(16)),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            if (_reconnectAttempts >= _maxReconnectAttempts && _reconnectStatus != null)
              const Icon(Icons.error_outline, color: Colors.orange, size: 36),
            if (_reconnectAttempts < _maxReconnectAttempts || _reconnectStatus == null)
              const CircularProgressIndicator(color: Colors.orange),
            const SizedBox(height: 14),
            Text(_reconnectStatus ?? 'Запускаю ${widget.quality}...', textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white, fontSize: 16)),
            if (_reconnectAttempts >= _maxReconnectAttempts) ...[
              const SizedBox(height: 12),
              ElevatedButton(style: ElevatedButton.styleFrom(backgroundColor: Colors.orange),
                onPressed: () { setState(() { _reconnectAttempts = 0; _reconnectStatus = null; }); _initPlayer(); },
                child: const Text('Попробовать снова', style: TextStyle(color: Colors.black))),
              const SizedBox(height: 6),
              TextButton(onPressed: () { if (mounted) Navigator.pop(context); },
                child: const Text('Выйти', style: TextStyle(color: Colors.white54))),
            ],
          ]),
        ),
      )),
    );
  }

  Widget _buildTopBar(String epLabel, bool hasEpisodes, int totalEpisodes,
      List<String> translations, String currentTranslation, List<SeriesEpisode> filteredEpisodes) {
    final filteredIndex = filteredEpisodes.indexWhere((e) =>
        e.link == (widget.currentEpisodeIndex < (widget.episodes?.length ?? 0)
            ? widget.episodes![widget.currentEpisodeIndex].link : ''));
    return Container(
      height: 46,
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.65),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(children: [
        GestureDetector(
          onTap: () { ApiService.stopSession(widget.sessionId); if (mounted) Navigator.pop(context); },
          child: const Padding(padding: EdgeInsets.symmetric(horizontal: 4), child: Icon(Icons.close, color: Colors.white, size: 22)),
        ),
        if (epLabel.isNotEmpty)
          Padding(padding: const EdgeInsets.symmetric(horizontal: 4), child: Text(epLabel, style: const TextStyle(color: Colors.orange, fontSize: 13, fontWeight: FontWeight.bold))),
        const Spacer(),
        if (hasEpisodes && widget.currentEpisodeIndex > 0)
          GestureDetector(onTap: () => widget.onEpisodeChange?.call(widget.currentEpisodeIndex - 1),
            child: const Padding(padding: EdgeInsets.all(8), child: Icon(Icons.skip_previous, color: Colors.white, size: 22))),
        if (hasEpisodes && filteredEpisodes.length > 1)
          GestureDetector(onTap: () => _showEpisodeList(filteredEpisodes, filteredIndex),
            child: const Padding(padding: EdgeInsets.all(8), child: Icon(Icons.list, color: Colors.white70, size: 22))),
        if (hasEpisodes && widget.currentEpisodeIndex < totalEpisodes - 1)
          GestureDetector(onTap: () => widget.onEpisodeChange?.call(widget.currentEpisodeIndex + 1),
            child: const Padding(padding: EdgeInsets.all(8), child: Icon(Icons.skip_next, color: Colors.white, size: 22))),
        if (translations.length > 1)
          GestureDetector(onTap: () => _showTranslationList(translations, currentTranslation),
            child: Padding(padding: const EdgeInsets.symmetric(horizontal: 6),
              child: Text(currentTranslation.length > 10 ? '${currentTranslation.substring(0, 10)}\u2026' : currentTranslation,
                  style: const TextStyle(color: Colors.white70, fontSize: 11))),
          ),
        GestureDetector(onTap: _showQualityDialog,
          child: const Padding(padding: EdgeInsets.all(8), child: Icon(Icons.settings, color: Colors.orange, size: 20))),
        GestureDetector(onTap: _isDownloading ? null : _downloadCurrentSession,
          child: Padding(padding: const EdgeInsets.all(8),
            child: _isDownloading ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.orange))
                : const Icon(Icons.download, color: Colors.white70, size: 20))),
      ]),
    );
  }

  void _showEpisodeList(List<SeriesEpisode> episodes, int currentIdx) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.black87,
      builder: (_) => SizedBox(height: 400, child: ListView.builder(
        itemCount: episodes.length,
        itemBuilder: (_, i) {
          final ep = episodes[i];
          final globalIdx = widget.episodes?.indexWhere((e) => e.link == ep.link) ?? -1;
          return ListTile(
            title: Text(ep.displayNumber, style: TextStyle(color: i == currentIdx ? Colors.orange : Colors.white70)),
            subtitle: Text(ep.title, style: const TextStyle(color: Colors.white54, fontSize: 12)),
            trailing: i == currentIdx ? const Icon(Icons.play_arrow, color: Colors.orange, size: 18) : null,
            onTap: () { Navigator.pop(context); if (globalIdx >= 0) widget.onEpisodeChange?.call(globalIdx); },
          );
        },
      )),
    );
  }

  void _showTranslationList(List<String> translations, String current) {
    final currentEp = widget.currentEpisodeIndex >= 0 && widget.currentEpisodeIndex < (widget.episodes?.length ?? 0)
        ? widget.episodes![widget.currentEpisodeIndex] : null;
    final currentSeason = currentEp?.season ?? '';
    final currentEpNum = currentEp?.episode ?? '';

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.black87,
      builder: (_) => SizedBox(height: 300, child: ListView(children: translations.map((t) {
        final matchingIdx = widget.episodes?.indexWhere((e) =>
            (e.translation ?? '') == t && (e.season ?? '') == currentSeason && (e.episode ?? '') == currentEpNum) ?? -1;
        return ListTile(
          title: Text(t, style: TextStyle(color: t == current ? Colors.orange : Colors.white70,
              fontWeight: t == current ? FontWeight.bold : FontWeight.normal)),
          trailing: t == current ? const Icon(Icons.check, color: Colors.orange, size: 18) : null,
          onTap: () { Navigator.pop(context); if (matchingIdx >= 0) widget.onEpisodeChange?.call(matchingIdx); },
        );
      }).toList())),
    );
  }
}
