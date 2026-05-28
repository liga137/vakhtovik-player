import 'dart:async';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../models/youtube_video.dart';
import '../services/api_service.dart';
import 'player_screen.dart';

class YouTubeSearchScreen extends StatefulWidget {
  const YouTubeSearchScreen({super.key});

  @override
  State<YouTubeSearchScreen> createState() => _YouTubeSearchScreenState();
}

class _YouTubeSearchScreenState extends State<YouTubeSearchScreen>
    with SingleTickerProviderStateMixin {
  final _searchController = TextEditingController();
  final _subController = TextEditingController();
  late final TabController _tabController;
  List<YouTubeVideo> _searchResults = const [];
  List<YouTubeVideo> _fresh = const [];
  List<YouTubeVideo> _feed = const [];
  List<YouTubeVideo> _popular = const [];
  List<YouTubeVideo> _shorts = const [];
  List<Map<String, dynamic>> _subs = const [];
  bool _loadingFresh = false;
  bool _loadingSearch = false;
  bool _loadingFeed = false;
  bool _loadingPopular = false;
  bool _loadingShorts = false;
  bool _loadingSubs = false;
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
    _subController.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 6, vsync: this);
    _tabController.addListener(_onTabChanged);
    unawaited(ApiService.initLocalState().then((_) async {
      if (!mounted) return;
      setState(() {});
      _ensureFreshLoadedIfPossible();
      _ensureFeedLoadedIfPossible();
      if (ApiService.isYouTubeLoggedIn) {
        await _loadSubs();
      }
    }));
    _loadPopular();
    _loadShorts();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _ensureFreshLoadedIfPossible();
      _ensureFeedLoadedIfPossible();
    });
  }

  void _onTabChanged() {
    if (!mounted || _tabController.indexIsChanging) return;
    if (_tabController.index == 0) {
      _ensureFreshLoadedIfPossible();
    }
    if (_tabController.index == 1) {
      _ensureFeedLoadedIfPossible();
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
      final result = await ApiService.getYoutubeHome();
      final videos = ApiService.parseInnerTubeVideos(result);
      if (mounted) setState(() => _fresh = videos);
    } catch (e) {
      LogService.error(LogService.youtube, 'Ошибка "Главная"', e);
      if (mounted) _snack('Ошибка "Главная": $e');
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
      final items = await ApiService.youtubeFeed(limit: 40);
      if (mounted) setState(() => _feed = items);
    } catch (e) {
      if (mounted) _snack('Ошибка ленты: $e');
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
      final items = await ApiService.searchYouTube('youtube shorts', limit: 30);
      final normalized = items.map((v) {
        if (v.id.isNotEmpty) {
          return YouTubeVideo(
            id: v.id,
            title: v.title,
            channel: v.channel,
            duration: v.duration,
            thumbnail: v.thumbnail,
            url: 'https://www.youtube.com/shorts/${v.id}',
          );
        }
        return v;
      }).toList();
      if (mounted) setState(() => _shorts = normalized);
    } catch (e) {
      if (mounted) _snack('Ошибка Shorts: $e');
    } finally {
      if (mounted) setState(() => _loadingShorts = false);
    }
  }

  Future<void> _loadSubs() async {
    if (_loadingSubs) return;
    if (!await _ensureLogin()) return;
    setState(() => _loadingSubs = true);
    try {
      final items = await ApiService.youtubeSubscriptions();
      if (mounted) setState(() => _subs = items);
    } catch (e) {
      if (mounted) _snack('Ошибка подписок: $e');
    } finally {
      if (mounted) setState(() => _loadingSubs = false);
    }
  }

  Future<void> _addSub() async {
    if (!await _ensureLogin()) return;
    final text = _subController.text.trim();
    if (text.isEmpty) return;
    try {
      await ApiService.youtubeAddSubscription(text);
      _subController.clear();
      await _loadSubs();
      _snack('Подписка добавлена');
    } catch (e) {
      _snack('Ошибка: $e');
    }
  }

  Future<void> _importGoogleSubscriptions() async {
    if (!await _ensureLogin()) return;
    final state = DateTime.now().millisecondsSinceEpoch.toString();
    setState(() => _googleImporting = true);
    try {
      final url = ApiService.youtubeGoogleStartUrl(state);
      final ok =
          await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
      if (!ok) throw Exception('Не удалось открыть браузер');

      _googlePollTimer?.cancel();
      var ticks = 0;
      _googlePollTimer =
          Timer.periodic(const Duration(seconds: 3), (timer) async {
        ticks++;
        try {
          final status = await ApiService.youtubeGoogleStatus(state);
          if (status['done'] == true) {
            timer.cancel();
            final err = (status['error'] ?? '').toString();
            if (err.isNotEmpty) {
              _snack('Ошибка импорта: $err');
            } else {
              _snack('Импортировано подписок: ${status['imported'] ?? 0}');
              await _loadSubs();
              await _loadFeed();
            }
            if (mounted) setState(() => _googleImporting = false);
          }
          if (ticks > 120) {
            timer.cancel();
            if (mounted) setState(() => _googleImporting = false);
            _snack(
                'Импорт не завершён. Проверь OAuth Production в Google Console.');
          }
        } catch (_) {}
      });
    } catch (e) {
      if (mounted) setState(() => _googleImporting = false);
      _snack(
          'Ошибка: $e. Если видишь "app not verified", переведи OAuth в Production.');
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
    final ok = await _showLoginDialog();
    return ok == true;
  }

  Future<bool?> _showLoginDialog() async {
    final user = TextEditingController();
    final pass = TextEditingController();
    var busy = false;
    Future<void> auth(BuildContext context,
        void Function(void Function()) setDialogState, bool register) async {
      setDialogState(() => busy = true);
      try {
        if (register) {
          await ApiService.youtubeRegister(user.text, pass.text);
        } else {
          await ApiService.youtubeLogin(user.text, pass.text);
        }
        if (context.mounted) Navigator.pop(context, true);
      } catch (e) {
        final msg = e.toString().contains('401')
            ? 'Аккаунт не найден. Нажми «Создать» если впервые.'
            : e.toString().contains('400') && e.toString().contains('exists')
                ? 'Аккаунт уже существует. Нажми «Войти».'
                : 'Ошибка: $e';
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
              content: Text(msg), duration: const Duration(seconds: 5)));
        }
      } finally {
        setDialogState(() => busy = false);
      }
    }

    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Аккаунт YouTube-раздела'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                  controller: user,
                  decoration: const InputDecoration(labelText: 'Логин')),
              TextField(
                  controller: pass,
                  obscureText: true,
                  decoration: const InputDecoration(labelText: 'Пароль')),
              const SizedBox(height: 12),
              const Text(
                'Это локальный аккаунт Плеера Вахтовика, не Google. Первый раз нажми «Создать».',
                style: TextStyle(fontSize: 12, color: Colors.white70),
              ),
              if (busy) const LinearProgressIndicator(color: Colors.orange),
            ],
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Отмена')),
            TextButton(
              onPressed:
                  busy ? null : () => auth(context, setDialogState, true),
              child: const Text('Создать'),
            ),
            FilledButton(
              onPressed:
                  busy ? null : () => auth(context, setDialogState, false),
              child: const Text('Войти'),
            ),
          ],
        ),
      ),
    );
    user.dispose();
    pass.dispose();
    if (mounted) setState(() {});
    if (result == true) {
      _ensureFreshLoadedIfPossible();
      _ensureFeedLoadedIfPossible();
      unawaited(_loadSubs());
    }
    return result;
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
          _feed = const [];
          _subs = const [];
        }),
        icon: const Icon(Icons.logout, color: Colors.orange),
        label: Text(ApiService.youtubeUsername ?? 'Выйти',
            style: const TextStyle(color: Colors.white)),
      );
    }
    return TextButton.icon(
      onPressed: _showLoginDialog,
      icon: const Icon(Icons.person, color: Colors.orange),
      label: const Text('Войти', style: TextStyle(color: Colors.white)),
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
    return Column(children: [
      Padding(
          padding: const EdgeInsets.all(8),
          child: Row(children: [
            const Expanded(
                child: Text('Главная страница YouTube',
                    style: TextStyle(color: Colors.white70))),
            FilledButton.icon(
                onPressed: _loadFresh,
                icon: const Icon(Icons.refresh),
                label: const Text('Обновить')),
          ])),
      Expanded(
          child: _videoGrid(_fresh,
              loading: _loadingFresh,
              empty: const Center(
                  child: Text(
                      'Пока пусто. Открой несколько видео, и здесь появятся новинки.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.white70))))),
    ]);
  }

  Widget _feedTab() {
    if (ApiService.isYouTubeLoggedIn && _feed.isEmpty && !_loadingFeed) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _tabController.index == 1) {
          _ensureFeedLoadedIfPossible();
        }
      });
    }
    return Column(children: [
      Padding(
          padding: const EdgeInsets.all(8),
          child: Row(children: [
            Expanded(
                child: Text(
                    ApiService.isYouTubeLoggedIn
                        ? 'Лента подписок'
                        : 'Войди, чтобы видеть свою ленту',
                    style: const TextStyle(color: Colors.white70))),
            FilledButton.icon(
                onPressed: _loadFeed,
                icon: const Icon(Icons.refresh),
                label: const Text('Обновить')),
          ])),
      Expanded(
          child: _videoGrid(_feed,
              loading: _loadingFeed,
              empty: Center(
                  child: Text(
                      ApiService.isYouTubeLoggedIn
                          ? 'Нет видео. Добавь подписки.'
                          : 'Нужен вход.',
                      style: const TextStyle(color: Colors.white70))))),
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
          padding: const EdgeInsets.all(8),
          child: Row(
            children: [
              const Expanded(
                child: Text('YouTube Shorts',
                    style: TextStyle(color: Colors.white70)),
              ),
              FilledButton.icon(
                onPressed: _loadShorts,
                icon: const Icon(Icons.refresh),
                label: const Text('Обновить'),
              ),
            ],
          ),
        ),
        Expanded(
          child: _videoGrid(
            _shorts,
            loading: _loadingShorts,
            empty: const Center(
                child: Text('Shorts пока пусто',
                    style: TextStyle(color: Colors.white70))),
          ),
        ),
      ],
    );
  }

  Widget _subsTab() {
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
        child: SizedBox(
          width: double.infinity,
          child: Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed:
                      _googleImporting ? null : _importGoogleSubscriptions,
                  icon: _googleImporting
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.cloud_download),
                  label: Text(_googleImporting
                      ? 'Жду вход Google...'
                      : 'Импортировать подписки из Google'),
                ),
              ),
              const SizedBox(width: 8),
              IconButton(
                onPressed: _showOAuthProductionHelp,
                tooltip: 'Как вывести OAuth в Production',
                icon: const Icon(Icons.info_outline, color: Colors.orange),
              ),
            ],
          ),
        ),
      ),
      Padding(
          padding: const EdgeInsets.all(8),
          child: Row(children: [
            Expanded(
                child: TextField(
                    controller: _subController,
                    decoration: const InputDecoration(
                        hintText: 'channel_id или ссылка /channel/UC...',
                        border: OutlineInputBorder()))),
            const SizedBox(width: 8),
            IconButton(
                onPressed: _addSub,
                icon: const Icon(Icons.add, color: Colors.orange)),
            IconButton(
                onPressed: _loadSubs,
                icon: const Icon(Icons.refresh, color: Colors.white)),
          ])),
      Expanded(
          child: _loadingSubs
              ? const Center(
                  child: CircularProgressIndicator(color: Colors.orange))
              : _subs.isEmpty
                  ? Center(
                      child: Text(
                          ApiService.isYouTubeLoggedIn
                              ? 'Подписок нет. Добавь channel_id.'
                              : 'Нужен вход.',
                          style: const TextStyle(color: Colors.white70)))
                  : ListView.builder(
                      itemCount: _subs.length,
                      itemBuilder: (_, i) {
                        final s = _subs[i];
                        return ListTile(
                            leading: const Icon(Icons.subscriptions,
                                color: Colors.orange),
                            title: Text((s['channel_name'] ?? s['channel_id'])
                                .toString()),
                            subtitle: Text((s['channel_id'] ?? '').toString()),
                            onTap: _loadFeed);
                      })),
    ]);
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
          Tab(icon: Icon(Icons.home), text: 'Лента'),
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
            _feedTab(),
            _searchTab(),
            _popularTab(),
            _shortsTab(),
            _subsTab()
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
