import 'package:flutter/material.dart';
import '../models/preset.dart';
import '../services/api_service.dart';
import 'player_screen.dart';

/// Главный экран: ввод ссылки + выбор качества
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _urlController = TextEditingController();
  List<Preset> _presets = [];
  String _selectedQuality = '360p';
  bool _loadingPresets = true;
  bool _starting = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadPresets();
  }

  Future<void> _loadPresets() async {
    try {
      final presets = await ApiService.getPresets();
      setState(() {
        _presets = presets;
        _loadingPresets = false;
        if (presets.isNotEmpty) _selectedQuality = presets.first.id;
      });
    } catch (e) {
      setState(() {
        _loadingPresets = false;
        _error = 'Нет связи с сервером: $e';
      });
    }
  }

  Future<void> _startTranscode() async {
    final url = _urlController.text.trim();
    if (url.isEmpty) {
      setState(() => _error = 'Вставь ссылку на видео');
      return;
    }
    setState(() {
      _starting = true;
      _error = null;
    });

    try {
      final result = await ApiService.transcode(url: url, quality: _selectedQuality);
      final hlsUrl = ApiService.hlsUrl(result.playlistUrl);

      if (!mounted) return;
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => PlayerScreen(
            hlsUrl: hlsUrl,
            sessionId: result.sessionId,
            sourceUrl: url,
            quality: _selectedQuality,
            duration: result.duration,
          ),
        ),
      );
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      setState(() => _starting = false);
    }
  }

  @override
  void dispose() {
    _urlController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Плеер Вахтовика'),
        centerTitle: true,
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Поле ввода URL
            TextField(
              controller: _urlController,
              decoration: InputDecoration(
                labelText: 'Ссылка на видео',
                hintText: 'https://...',
                border: const OutlineInputBorder(),
                suffixIcon: IconButton(
                  icon: const Icon(Icons.clear),
                  onPressed: () => _urlController.clear(),
                ),
              ),
              keyboardType: TextInputType.url,
            ),
            const SizedBox(height: 16),

            // Выбор качества
            const Text('Качество:', style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            if (_loadingPresets)
              const Center(child: CircularProgressIndicator())
            else if (_error != null && _presets.isEmpty)
              Text(_error!, style: const TextStyle(color: Colors.red))
            else
              Wrap(
                spacing: 8,
                children: _presets.map((preset) {
                  final selected = _selectedQuality == preset.id;
                  return ChoiceChip(
                    label: Text(preset.label),
                    selected: selected,
                    onSelected: (_) => setState(() => _selectedQuality = preset.id),
                  );
                }).toList(),
              ),
            const SizedBox(height: 24),

            // Ошибка
            if (_error != null && _presets.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(_error!, style: const TextStyle(color: Colors.red)),
              ),

            // Кнопка запуска
            ElevatedButton.icon(
              onPressed: _starting ? null : _startTranscode,
              icon: _starting
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.play_arrow),
              label: Text(_starting ? 'Запуск...' : 'Смотреть'),
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 14),
                textStyle: const TextStyle(fontSize: 18),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
