import 'package:flutter/material.dart';
import '../models/youtube_video.dart';
import '../services/api_service.dart';
import 'player_screen.dart';

class YouTubeSearchScreen extends StatefulWidget {
  const YouTubeSearchScreen({super.key});

  @override
  State<YouTubeSearchScreen> createState() => _YouTubeSearchScreenState();
}

class _YouTubeSearchScreenState extends State<YouTubeSearchScreen> {
  final _controller = TextEditingController();
  List<YouTubeVideo> _results = const [];
  bool _loading = false;
  bool _starting = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final q = _controller.text.trim();
    if (q.isEmpty || _loading) return;
    setState(() => _loading = true);
    try {
      final items = await ApiService.searchYouTube(q, limit: 12);
      if (mounted) setState(() => _results = items);
    } catch (e) {
      if (mounted) _snack('Ошибка поиска: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _play(YouTubeVideo video) async {
    if (_starting) return;
    setState(() => _starting = true);
    try {
      final targetUrl = video.url.isNotEmpty
          ? video.url
          : 'https://www.youtube.com/watch?v=${video.id}';
      final result = await ApiService.transcode(
        url: targetUrl,
        quality: '240p',
        referer: 'https://www.youtube.com/',
      );
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => PlayerScreen(
            hlsUrl: ApiService.hlsUrl(result.playlistUrl),
            sessionId: result.sessionId,
          ),
        ),
      );
    } catch (e) {
      if (mounted) _snack('Ошибка запуска: $e');
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  void _snack(String text) {
    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(text), duration: const Duration(seconds: 4)));
  }

  String _formatDuration(int seconds) {
    if (seconds <= 0) return '';
    final h = seconds ~/ 3600;
    final m = (seconds % 3600) ~/ 60;
    final s = seconds % 60;
    if (h > 0) {
      return '$h:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
    }
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF111111),
      appBar: AppBar(
        title: const Text('YouTube без рекламы'),
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
      ),
      body: Stack(
        children: [
          Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(12),
                child: TextField(
                  controller: _controller,
                  autofocus: true,
                  textInputAction: TextInputAction.search,
                  onSubmitted: (_) => _search(),
                  decoration: InputDecoration(
                    hintText: 'Поиск YouTube...',
                    prefixIcon: const Icon(Icons.search),
                    suffixIcon: IconButton(
                        onPressed: _search,
                        icon: const Icon(Icons.arrow_forward)),
                    filled: true,
                    fillColor: const Color(0xFF1E1E1E),
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12)),
                  ),
                ),
              ),
              if (_loading) const LinearProgressIndicator(color: Colors.orange),
              Expanded(
                child: _results.isEmpty && !_loading
                    ? const Center(
                        child: Text(
                          'Введи запрос. Видео пойдёт через сервер в 240p.',
                          style: TextStyle(color: Colors.white70),
                          textAlign: TextAlign.center,
                        ),
                      )
                    : ListView.separated(
                        padding: const EdgeInsets.fromLTRB(8, 8, 8, 24),
                        itemCount: _results.length,
                        separatorBuilder: (_, __) =>
                            const Divider(height: 1, color: Colors.white12),
                        itemBuilder: (context, index) {
                          final v = _results[index];
                          final dur = _formatDuration(v.duration);
                          return ListTile(
                            contentPadding: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 6),
                            leading: ClipRRect(
                              borderRadius: BorderRadius.circular(6),
                              child: v.thumbnail.isEmpty
                                  ? Container(
                                      width: 112,
                                      height: 64,
                                      color: Colors.black26,
                                      child: const Icon(Icons.play_circle,
                                          color: Colors.orange))
                                  : Image.network(
                                      v.thumbnail,
                                      width: 112,
                                      height: 64,
                                      fit: BoxFit.cover,
                                      errorBuilder: (_, __, ___) => Container(
                                          width: 112,
                                          height: 64,
                                          color: Colors.black26),
                                    ),
                            ),
                            title: Text(v.title,
                                maxLines: 2, overflow: TextOverflow.ellipsis),
                            subtitle: Text(
                              [v.channel, dur]
                                  .where((e) => e.isNotEmpty)
                                  .join(' · '),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(color: Colors.white60),
                            ),
                            trailing: const Icon(Icons.play_arrow,
                                color: Colors.orange),
                            onTap: () => _play(v),
                          );
                        },
                      ),
              ),
            ],
          ),
          if (_starting)
            Container(
              color: Colors.black54,
              child: const Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircularProgressIndicator(color: Colors.orange),
                    SizedBox(height: 12),
                    Text('Запускаю 240p...',
                        style: TextStyle(color: Colors.white)),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
