import 'dart:async';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../models/youtube_video.dart';
import '../services/api_service.dart';
import '../services/log_service.dart';
import 'player_screen.dart';
import 'youtube_login_screen.dart';

class YouTubeSearchScreen extends StatefulWidget {
  const YouTubeSearchScreen({super.key});

  @override
  State<YouTubeSearchScreen> createState() => _YouTubeSearchScreenState();
}

class _YouTubeSearchScreenState extends State<YouTubeSearchScreen>
    with SingleTickerProviderStateMixin {
  final _searchController = TextEditingController();
  late final TabController _tabController;
  List<YouTubeVideo> _searchResults = const [];
  List<YouTubeVideo> _fresh = const [];
  List<YouTubeVideo> _feed = const [];
  List<YouTubeVideo> _popular = const [];
  List<YouTubeVideo> _shorts = const [];
  bool _loadingFresh = false;
  bool _loadingSearch = false;
  bool _loadingFeed = false;
  bool _loadingPopular = false;
  bool _loadingShorts = false;
  bool _starting = false;
  bool _googleImporting = false;
  Timer? _googlePollTimer;
  String _quality = '240p';
  bool _freshAutoRequested = false;
  bool _feedAutoRequested = false;

  static const _quickSearches = [
    'Лавкрафт аудиокнига Булдаков',
    'документальные фильмы космос',
    'музыка в дорогу',
    'ремонт авто диагностика',
    'интересные факты',
    'аудиокнига фантастика',
  ];

  @override
  void dispose() {
    _googlePollTimer?.cancel();
    _tabController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 5, vsync: this);
    _tabController.addListener(_onTabChanged);
    unawaited(ApiService.initLocalState().then((_) async {
      if (!mounted) return;
      setState(() {});
      _ensureFreshLoadedIfPossible();
      if (ApiService.isYouTubeLoggedIn) {
        await _loadFeed();
      }
    }));
    _loadPopular();
    _loadShorts();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _ensureFreshLoadedIfPossible();
    });
  }

  void _onTabChanged() {
    if (!mounted || _tabController.indexIsChanging) return;
    if (_tabController.index == 0) {
      _ensureFreshLoadedIfPossible();
    }
  }

  void _ensureFreshLoadedIfPossible() {
    if (_fresh.isNotEmpty || _freshAutoRequested) return;
    if (_loadingFresh) {
      Future.delayed(const Duration(milliseconds: 700), () {
        if (mounted) _ensureFreshLoadedIfPossible();
      });
      return;
    }
    _freshAutoRequested = true;
    unawaited(_loadFresh().whenComplete(() {
      if (mounted && _fresh.isEmpty) {
        _freshAutoRequested = false;
      }
    }));
  }

  void _ensureFeedLoadedIfPossible() {
    if (!ApiService.isYouTubeLoggedIn) return;
    if (_feed.isNotEmpty || _feedAutoRequested) return;
    if (_loadingFeed) {
      Future.delayed(const Duration(milliseconds: 700), () {
        if (mounted) _ensureFeedLoadedIfPossible();
      });
      return;
    }
    _feedAutoRequested = true;
    unawaited(_loadFeed().whenComplete(() {
      if (mounted && _feed.isEmpty) {
        _feedAutoRequested = false;
      }
    }));
  }

  Future<void> _loadFresh() async {
    if (_loadingFresh) return;
    setState(() => _loadingFresh = true);
    try {
      // Серверный InnerTube: с токеном — персональная, без — популярное
      final videos = await ApiService.youtubeHome(limit: 24);
      if (videos.isEmpty && ApiService.isYouTubeLoggedIn) {
        // Пустой ответ при авторизации — не разлогиниваем, просто сообщаем
        if (mounted) _snack('Главная: пустой ответ сервера. Попробуйте позже.');
      } else {
        if (mounted) setState(() => _fresh = videos);
      }
    } catch (e) {
      final msg = e.toString();
      LogService.error(LogService.youtube, 'Ошибка Главной', e);
      // Fallback: популярное через yt-dlp
      if (!msg.contains('AUTH')) {
        try {
          final items = await ApiService.youtubePopular(limit: 24);
          if (mounted) setState(() => _fresh = items);
        } catch (_) {}
      }
    } finally {
      if (mounted) setState(() => _loadingFresh = false);
    }
  }

  Future<void> _search([String? query]) async {
    if (query != null) _searchController.text = query;
    final q = _searchController.text.trim();
    if (q.isEmpty || _loadingSearch) return;
    setState(() => _loadingSearch = true);
    try {
      final items = await ApiService.searchYouTube(q, limit: 12);
      if (mounted) setState(() => _searchResults = items);
    } catch (e) {
      if (mounted) _snack('Ошибка поиска: $e');
    } finally {
      if (mounted) setState(() => _loadingSearch = false);
    }
  }

  Future<void> _loadFeed() async {
    if (_loadingFeed) return;
    if (!await _ensureLogin()) return;
    setState(() => _loadingFeed = true);
    try {
      // Серверный InnerTube для подписок
      final videos = await ApiService.youtubeSubscriptions(limit: 30);
      if (videos.isEmpty) {
        if (mounted) _snack('Лента пуста — возможно, нет подписок или ошибка сервера.');
      } else {
        if (mounted) setState(() => _feed = videos);
      }
    } catch (e) {
      final msg = e.toString();
      if (msg.contains('AUTH_ERROR') || msg.contains('401')) {
        ApiService.youtubeLogout();
        if (mounted) {
          setState(() => _feed = const []);
          _snack('Сессия истекла. Войдите заново.');
        }
      } else if (msg.contains('AUTH_REQUIRED')) {
        if (mounted) _snack('Нужен вход через Google.');
      } else {
        if (mounted) _snack('Ошибка подписок: ${msg.split(":").first}');
      }
    } finally {
      if (mounted) setState(() => _loadingFeed = false);
    }
  }

  Future<void> _loadPopular() async {
    if (_loadingPopular) return;
    setState(() => _loadingPopular = true);
    try {
      final items = await ApiService.youtubePopular(limit: 24);
      if (mounted) setState(() => _popular = items);
    } catch (e) {
      if (mounted) _snack('Ошибка популярного: $e');
    } finally {
      if (mounted) setState(() => _loadingPopular = false);
    }
  }

  Future<void> _loadShorts() async {
    if (_loadingShorts) return;
    setState(() => _loadingShorts = true);
    try {
      // Серверный InnerTube для Shorts — MWEB FEshorts + fallback
      final videos = await ApiService.youtubeShorts(limit: 20);
      if (mounted) setState(() => _shorts = videos);
    } catch (e) {
      LogService.error(LogService.youtube, 'Ошибка загрузки Shorts', e);
      if (mounted) _snack('Shorts: ${e.toString().split(":").first}');
    } finally {
      if (mounted) setState(() => _loadingShorts = false);
    }
  }

  Future<void> _importGoogleSubscriptions() async {
    final result = await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => const YouTubeLoginScreen(),
    ));

    if (result == true) {
      // Успешный вход
      _snack('Вход выполнен: ${ApiService.youtubeUsername ?? "YouTube"}');
      await _loadFeed();
      await _loadFresh();
      await _loadShorts();
    }
  }

  void _showOAuthProductionHelp() {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Google OAuth Production'),
        content: const SingleChildScrollView(
          child: Text(
            '1. Google Cloud Console → OAuth consent screen → Publish app.\n'
            '2. Добавь домен сервера в Authorized domains.\n'
            '3. Проверь Redirect URI сервера (эндпоинт /yt/google/start использует серверный callback).\n'
            '4. Добавь тестовые/боевые YouTube scope и отправь на верификацию, если требуется.\n'
            '5. После публикации перепроверь импорт подписок из этого экрана.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Закрыть'),
          ),
        ],
      ),
    );
  }

  Future<bool> _ensureLogin() async {
    if (ApiService.isYouTubeLoggedIn) return true;
    _snack('Нужен вход через Google');
    return false;
  }

  Future<void> _play(YouTubeVideo video) async {
    if (_starting) return;
    setState(() => _starting = true);
    try {
      if (video.channel.trim().isNotEmpty) {
        unawaited(ApiService.youtubeRememberWatchedChannel(video.channel));
      }
      final targetUrl = video.url.isNotEmpty
          ? video.url
          : 'https://www.youtube.com/watch?v=${video.id}';
      final result = await ApiService.transcode(
          url: targetUrl,
          quality: _quality,
          referer: 'https://www.youtube.com/');
      if (!mounted) return;
      await Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => PlayerScreen(
                hlsUrl: ApiService.hlsUrl(result.playlistUrl),
                sessionId: result.sessionId,
                sourceUrl: targetUrl,
                quality: _quality,
                referer: 'https://www.youtube.com/',
                duration: result.duration,
              )));
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

  Widget _qualityButton() {
    return PopupMenuButton<String>(
      tooltip: 'Качество',
      initialValue: _quality,
      onSelected: (v) => setState(() => _quality = v),
      itemBuilder: (_) => const [
        PopupMenuItem(value: '144p', child: Text('144p')),
        PopupMenuItem(value: '240p', child: Text('240p')),
        PopupMenuItem(value: '360p', child: Text('360p')),
        PopupMenuItem(value: '480p', child: Text('480p')),
      ],
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Row(children: [
          const Icon(Icons.settings, color: Colors.orange),
          const SizedBox(width: 4),
          Text(_quality)
        ]),
      ),
    );
  }

  Widget _loginButton() {
    if (ApiService.isYouTubeLoggedIn) {
      return TextButton.icon(
        onPressed: () => setState(() {
          ApiService.youtubeLogout();
          _fresh = const [];
          _feed = const [];
        }),
        icon: const Icon(Icons.logout, color: Colors.orange),
        label: Text(ApiService.youtubeUsername ?? 'Выйти',
            style: const TextStyle(color: Colors.white)),
      );
    }
    return TextButton.icon(
      onPressed: _importGoogleSubscriptions,
      icon: const Icon(Icons.login, color: Colors.orange),
      label: const Text('Войти через Google', style: TextStyle(color: Colors.white)),
    );
  }

  Widget _emptySearch() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(
              'Выбери подборку или введи запрос. Видео пойдёт через сервер в $_quality.',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white70)),
          const SizedBox(height: 18),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            alignment: WrapAlignment.center,
            children: _quickSearches
                .map((q) => ActionChip(
                    label: Text(q),
                    onPressed: () => _search(q),
                    backgroundColor: const Color(0xFF242424),
                    labelStyle: const TextStyle(color: Colors.white),
                    side: const BorderSide(color: Colors.white24)))
                .toList(),
          ),
        ]),
      ),
    );
  }

  Widget _videoGrid(List<YouTubeVideo> items,
      {Widget? empty, bool loading = false}) {
    if (loading) {
      return const Center(
          child: CircularProgressIndicator(color: Colors.orange));
    }
    if (items.isEmpty) {
      return empty ??
          const Center(
              child: Text('Пусто', style: TextStyle(color: Colors.white70)));
    }
    return LayoutBuilder(builder: (context, constraints) {
      final width = constraints.maxWidth;
      var crossAxisCount = 1;
      if (width >= 1280) {
        crossAxisCount = 4;
      } else if (width >= 960) {
        crossAxisCount = 3;
      } else if (width >= 620) {
        crossAxisCount = 2;
      }
      final aspectRatio = crossAxisCount >= 4
          ? 1.03
          : (crossAxisCount == 3 ? 0.98 : (crossAxisCount == 2 ? 0.93 : 1.42));

      return GridView.builder(
        padding: const EdgeInsets.fromLTRB(8, 8, 8, 24),
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: crossAxisCount,
          childAspectRatio: aspectRatio,
          crossAxisSpacing: 8,
          mainAxisSpacing: 8,
        ),
        itemCount: items.length,
        itemBuilder: (_, i) => _videoCard(items[i]),
      );
    });
  }

  Widget _videoCard(YouTubeVideo v) {
    final dur = _formatDuration(v.duration);
    final meta = [v.viewsText, v.publishedText, if (dur.isNotEmpty) dur]
        .where((e) => e.trim().isNotEmpty)
        .join(' • ');
    return InkWell(
      onTap: () => _play(v),
      child: Container(
        decoration: BoxDecoration(
            color: const Color(0xFF1E1E1E),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: Colors.white12)),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AspectRatio(
                aspectRatio: 16 / 9,
                child: v.thumbnail.isEmpty
                    ? Container(
                        color: Colors.black26,
                        child:
                            const Icon(Icons.play_circle, color: Colors.orange))
                    : Image.network(v.thumbnail,
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) =>
                            Container(color: Colors.black26))),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(v.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontWeight: FontWeight.w700,
                          color: Colors.white,
                        )),
                    const SizedBox(height: 4),
                    Text(
                      v.channel.isNotEmpty ? v.channel : 'YouTube',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style:
                          const TextStyle(color: Colors.white70, fontSize: 12),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      meta.isNotEmpty ? meta : (dur.isNotEmpty ? dur : ' '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style:
                          const TextStyle(color: Colors.white60, fontSize: 12),
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

  Widget _freshTab() {
    final isLoggedIn = ApiService.isYouTubeLoggedIn;
    final headerText = isLoggedIn
        ? 'Персональная лента: ${ApiService.youtubeUsername ?? "YouTube"}'
        : 'YouTube — популярные видео';
    return Column(children: [
      Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 8, 4),
          child: Row(children: [
            Expanded(
                child: Text(headerText,
                    style: const TextStyle(color: Colors.white70, fontSize: 13),
                    overflow: TextOverflow.ellipsis)),
            if (_loadingFresh)
              const Padding(
                  padding: EdgeInsets.only(right: 8),
                  child: SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.orange))),
            TextButton.icon(
                onPressed: _loadingFresh ? null : _loadFresh,
                icon: const Icon(Icons.refresh, size: 18),
                label: const Text('Обновить'),
                style: TextButton.styleFrom(foregroundColor: Colors.orange)),
          ])),
      Expanded(
          child: _videoGrid(_fresh,
              loading: _loadingFresh && _fresh.isEmpty,
              empty: Center(
                  child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.home_outlined, size: 48, color: Colors.white24),
                  const SizedBox(height: 12),
                  Text(
                    isLoggedIn
                        ? 'Загрузка персональной ленты...\nПоробуйте обновить.'
                        : 'Войдите через Google для персональной ленты\nили подождите загрузки популярных.',
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white54, fontSize: 13),
                  ),
                  if (!isLoggedIn) ...[const SizedBox(height: 16), FilledButton.icon(
                    onPressed: _importGoogleSubscriptions,
                    icon: const Icon(Icons.login, size: 18),
                    label: const Text('Войти через Google'),
                    style: FilledButton.styleFrom(backgroundColor: Colors.red),
                  )]
                ],
              )))),
    ]);
  }

  Widget _feedTab() {
    if (ApiService.isYouTubeLoggedIn && _feed.isEmpty && !_loadingFeed) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _tabController.index == 4) {
          _ensureFeedLoadedIfPossible();
        }
      });
    }
    return Column(children: [
      Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 8, 4),
          child: Row(children: [
            Expanded(
                child: Text(
                    ApiService.isYouTubeLoggedIn
                        ? 'Подписки: ${ApiService.youtubeUsername ?? "YouTube"}'
                        : 'Подписки (нужен вход)',
                    style: const TextStyle(color: Colors.white70, fontSize: 13),
                    overflow: TextOverflow.ellipsis)),
            if (_loadingFeed)
              const Padding(
                  padding: EdgeInsets.only(right: 8),
                  child: SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.orange))),
            TextButton.icon(
                onPressed: _loadingFeed ? null : _loadFeed,
                icon: const Icon(Icons.refresh, size: 18),
                label: const Text('Обновить'),
                style: TextButton.styleFrom(foregroundColor: Colors.orange)),
          ])),
      Expanded(
          child: _videoGrid(_feed,
              loading: _loadingFeed && _feed.isEmpty,
              empty: Center(
                  child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                      ApiService.isYouTubeLoggedIn
                          ? Icons.subscriptions_outlined
                          : Icons.login,
                      size: 48,
                      color: Colors.white24),
                  const SizedBox(height: 12),
                  Text(
                    ApiService.isYouTubeLoggedIn
                        ? 'Нет видео в ленте подписок.\nПроверьте подписки на YouTube.'
                        : 'Войдите через Google,\nчтобы видеть свои подписки.',
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white54, fontSize: 13),
                  ),
                  if (!ApiService.isYouTubeLoggedIn) ...[const SizedBox(height: 16), FilledButton.icon(
                    onPressed: _importGoogleSubscriptions,
                    icon: const Icon(Icons.login, size: 18),
                    label: const Text('Войти через Google'),
                    style: FilledButton.styleFrom(backgroundColor: Colors.red),
                  )]
                ],
              )))),
    ]);
  }

  Widget _searchTab() {
    return Column(children: [
      Padding(
          padding: const EdgeInsets.all(12),
          child: TextField(
            controller: _searchController,
            autofocus: false,
            textInputAction: TextInputAction.search,
            onSubmitted: (_) => _search(),
            decoration: InputDecoration(
                hintText: 'Поиск YouTube...',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: IconButton(
                    onPressed: _search, icon: const Icon(Icons.arrow_forward)),
                filled: true,
                fillColor: const Color(0xFF1E1E1E),
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12))),
          )),
      Expanded(
          child: _videoGrid(_searchResults,
              loading: _loadingSearch, empty: _emptySearch())),
    ]);
  }

  Widget _popularTab() {
    return _videoGrid(_popular,
        loading: _loadingPopular,
        empty: const Center(
            child:
                Text('Загрузка...', style: TextStyle(color: Colors.white70))));
  }

  Widget _shortsTab() {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 8, 4),
          child: Row(
            children: [
              const Icon(Icons.smart_display, color: Colors.redAccent, size: 20),
              const SizedBox(width: 6),
              const Expanded(
                child: Text('YouTube Shorts',
                    style: TextStyle(color: Colors.white70, fontSize: 13)),
              ),
              if (_loadingShorts)
                const Padding(
                    padding: EdgeInsets.only(right: 8),
                    child: SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.orange))),
              TextButton.icon(
                onPressed: _loadingShorts ? null : _loadShorts,
                icon: const Icon(Icons.refresh, size: 18),
                label: const Text('Обновить'),
                style: TextButton.styleFrom(foregroundColor: Colors.orange),
              ),
            ],
          ),
        ),
        Expanded(
          child: _shorts.isEmpty && !_loadingShorts
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.smart_display_outlined,
                          size: 48, color: Colors.white24),
                      const SizedBox(height: 12),
                      const Text(
                        'Shorts пока не загружены.\nНажмите «Обновить».',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.white54, fontSize: 13),
                      ),
                      const SizedBox(height: 16),
                      TextButton.icon(
                        onPressed: _loadShorts,
                        icon: const Icon(Icons.refresh),
                        label: const Text('Загрузить Shorts'),
                        style: TextButton.styleFrom(
                            foregroundColor: Colors.orange),
                      ),
                    ],
                  ),
                )
              : _shortsGrid(),
        ),
      ],
    );
  }

  Widget _shortsGrid() {
    if (_loadingShorts && _shorts.isEmpty) {
      return const Center(
          child: CircularProgressIndicator(color: Colors.orange));
    }
    return LayoutBuilder(builder: (context, constraints) {
      final width = constraints.maxWidth;
      // Shorts — вертикальный формат 9:16
      var crossAxisCount = 2;
      if (width >= 900) crossAxisCount = 4;
      else if (width >= 600) crossAxisCount = 3;

      return GridView.builder(
        padding: const EdgeInsets.fromLTRB(8, 4, 8, 24),
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: crossAxisCount,
          childAspectRatio: 9 / 16,
          crossAxisSpacing: 8,
          mainAxisSpacing: 8,
        ),
        itemCount: _shorts.length,
        itemBuilder: (_, i) => _shortCard(_shorts[i]),
      );
    });
  }

  Widget _shortCard(YouTubeVideo v) {
    final dur = _formatDuration(v.duration);
    return InkWell(
      onTap: () => _play(v),
      borderRadius: BorderRadius.circular(12),
      child: Container(
        decoration: BoxDecoration(
            color: const Color(0xFF1A1A1A),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.white10)),
        clipBehavior: Clip.antiAlias,
        child: Stack(
          fit: StackFit.expand,
          children: [
            // Превью
            v.thumbnail.isEmpty
                ? Container(
                    color: Colors.black26,
                    child: const Icon(Icons.play_circle,
                        color: Colors.orange, size: 40))
                : Image.network(v.thumbnail,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) =>
                        Container(color: Colors.black38)),
            // Градиент снизу
            Positioned(
              bottom: 0,
              left: 0,
              right: 0,
              child: Container(
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Colors.transparent, Colors.black87],
                  ),
                ),
                padding: const EdgeInsets.fromLTRB(8, 24, 8, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(v.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                            fontWeight: FontWeight.w600)),
                    if (dur.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(dur,
                            style: const TextStyle(
                                color: Colors.white70, fontSize: 11)),
                      ),
                  ],
                ),
              ),
            ),
            // Shorts-значок
            Positioned(
              top: 8,
              right: 8,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                    color: Colors.red,
                    borderRadius: BorderRadius.circular(4)),
                child: const Text('SHORT',
                    style: TextStyle(
                        color: Colors.white,
                        fontSize: 10,
                        fontWeight: FontWeight.bold)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF111111),
      appBar: AppBar(
        title: const Text('YouTube без рекламы'),
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        actions: [_qualityButton(), _loginButton()],
        bottom: TabBar(controller: _tabController, tabs: const [
          Tab(icon: Icon(Icons.home), text: 'Главная'),
          Tab(icon: Icon(Icons.search), text: 'Поиск'),
          Tab(icon: Icon(Icons.trending_up), text: 'Популярное'),
          Tab(icon: Icon(Icons.smart_display), text: 'Shorts'),
          Tab(icon: Icon(Icons.subscriptions), text: 'Подписки')
        ]),
      ),
      body: Stack(children: [
        TabBarView(
          controller: _tabController,
          children: [
            _freshTab(),
            _searchTab(),
            _popularTab(),
            _shortsTab(),
            _feedTab()
          ],
        ),
        if (_starting)
          Container(
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
                    const CircularProgressIndicator(color: Colors.orange),
                    const SizedBox(height: 14),
                    Text('Запускаю $_quality...',
                        style:
                            const TextStyle(color: Colors.white, fontSize: 16)),
                  ],
                ),
              ),
            ),
          ),
      ]),
    );
  }
}
