import 'dart:async';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../services/api_service.dart';
import '../services/hls_proxy_service.dart';

class IptvPlayerScreen extends StatefulWidget {
  final String title;
  final String hlsUrl;
  final String sessionId;

  const IptvPlayerScreen({
    super.key,
    required this.title,
    required this.hlsUrl,
    required this.sessionId,
  });

  @override
  State<IptvPlayerScreen> createState() => _IptvPlayerScreenState();
}

class _IptvPlayerScreenState extends State<IptvPlayerScreen> {
  late final Player _player = Player();
  late final VideoController _controller = VideoController(_player);
  StreamSubscription? _errorSub;
  Timer? _retryTimer;
  bool _opening = true;
  bool _openingInProgress = false;
  bool _opened = false;
  int _openAttempt = 0;
  String _status = 'Готовим IPTV-поток...';
  static const int _minStartChunks = 6;

  @override
  void initState() {
    super.initState();
    _errorSub = _player.stream.error.listen((error) {
      final text = error.toString();
      if (!mounted || text.isEmpty || text == 'none') return;
      if (_opened && !_opening) return;
      _scheduleRetry();
    });
    unawaited(_open());
  }

  Future<void> _waitForFirstChunk() async {
    var waitedSeconds = 0;
    while (mounted) {
      try {
        final status = await ApiService.getStatusQuick(widget.sessionId)
            .timeout(const Duration(seconds: 6));
        final chunks = (status['chunks'] as num?)?.toInt() ?? 0;
        if (chunks >= _minStartChunks) return;
        if (mounted && chunks > 0) {
          setState(() {
            _opening = true;
            _status = 'Буфер IPTV: $chunks/$_minStartChunks чанка';
          });
          await Future<void>.delayed(const Duration(seconds: 1));
          continue;
        }
      } catch (_) {
        // На слабом канале статус может временно не отвечать. Для IPTV это
        // не ошибка плеера: продолжаем ждать и не пугаем пользователя.
      }

      waitedSeconds++;
      if (!mounted) return;
      setState(() {
        _opening = true;
        _status = waitedSeconds < 2
            ? 'Готовим IPTV-поток...'
            : 'Ждём IPTV-поток... $waitedSecondsс';
      });
      await Future<void>.delayed(const Duration(seconds: 1));
    }
  }

  Future<void> _open() async {
    if (_openingInProgress || !mounted) return;
    _retryTimer?.cancel();
    _retryTimer = null;
    _openingInProgress = true;
    _openAttempt++;

    setState(() {
      _opening = true;
      _status = _openAttempt == 1
          ? 'Готовим IPTV-поток...'
          : 'Ждём IPTV-поток... попытка $_openAttempt';
    });
    try {
      await _waitForFirstChunk();
      if (!mounted) return;
      var playUrl = widget.hlsUrl;
      try {
        setState(() {
          _opening = true;
          _status = 'Готовим локальный IPTV-буфер...';
        });
        await HlsProxyService.instance.start(widget.hlsUrl);
        final localUrl = HlsProxyService.instance.localPlaylistUrl;
        final ready = await HlsProxyService.instance.waitUntilReady();
        if (ready && localUrl.isNotEmpty) {
          playUrl = localUrl;
        } else {
          await HlsProxyService.instance.stop();
        }
      } catch (_) {
        await HlsProxyService.instance.stop();
      }
      await _player.stop();
      await _applyLiveMpvProperties();
      await _player.open(Media(playUrl), play: true);
      if (!mounted) return;
      setState(() {
        _opened = true;
        _opening = false;
      });
    } catch (_) {
      if (!mounted) return;
      _openingInProgress = false;
      _scheduleRetry();
    } finally {
      _openingInProgress = false;
    }
  }

  Future<void> _applyLiveMpvProperties() async {
    final platform = _player.platform;
    if (platform == null) return;

    const commands = <List<String>>[
      ['set', 'cache', 'yes'],
      ['set', 'cache-pause', 'no'],
      ['set', 'cache-pause-initial', 'no'],
      ['set', 'cache-secs', '120'],
      ['set', 'cache-back-secs', '30'],
      ['set', 'stream-buffer-size', '64MiB'],
      ['set', 'demuxer-max-bytes', '100MiB'],
      ['set', 'demuxer-max-back-bytes', '50MiB'],
      ['set', 'demuxer-readahead-secs', '120'],
      ['set', 'hls-bitrate', 'max'],
      ['set', 'hls-segment-threads', '4'],
      ['set', 'video-sync', 'audio'],
      ['set', 'correct-pts', 'yes'],
      ['set', 'framedrop', 'vo'],
    ];

    for (final command in commands) {
      try {
        await (platform as dynamic).command(command);
      } on NoSuchMethodError {
        return;
      } catch (_) {
        // A rejected mpv option must not prevent IPTV playback from starting.
      }
    }
  }

  void _scheduleRetry() {
    if (!mounted || _openingInProgress || (_retryTimer?.isActive ?? false)) {
      return;
    }
    setState(() {
      _opening = true;
      _status = 'IPTV-поток ещё загружается...';
    });
    _retryTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) unawaited(_open());
    });
  }

  @override
  void dispose() {
    _retryTimer?.cancel();
    _errorSub?.cancel();
    HlsProxyService.instance.stop().catchError((_) {});
    ApiService.stopSession(widget.sessionId).catchError((_) {});
    _player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          Video(controller: _controller),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              child: Container(
                height: 44,
                margin: const EdgeInsets.all(8),
                padding: const EdgeInsets.symmetric(horizontal: 4),
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.65),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  children: [
                    IconButton(
                      icon: const Icon(Icons.close, color: Colors.white),
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                    Expanded(
                      child: Text(
                        widget.title,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.orange,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (_opening) _buildLoading(),
        ],
      ),
    );
  }

  Widget _buildLoading() {
    return Container(
      color: Colors.black54,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(color: Colors.orange),
            const SizedBox(height: 16),
            Text(
              _status,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
