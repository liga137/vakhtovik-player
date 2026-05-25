import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'hysteria_service.dart';

class AppUpdateInfo {
  final bool hasUpdate;
  final String currentVersion;
  final String latestVersion;
  final String htmlUrl;
  final String releaseNotes;
  final String windowsAssetUrl;
  final String androidAssetUrl;

  const AppUpdateInfo({
    required this.hasUpdate,
    required this.currentVersion,
    required this.latestVersion,
    required this.htmlUrl,
    required this.releaseNotes,
    required this.windowsAssetUrl,
    required this.androidAssetUrl,
  });
}

class UpdateService {
  static const _repoApiUrl = 'https://api.github.com/repos/liga137/vakhtovik-player/releases/latest';
  static http.Client get _client => IOClient(HysteriaService.createProxyClient());

  static Future<AppUpdateInfo> checkLatest() async {
    final pkg = await PackageInfo.fromPlatform();
    final current = pkg.version;
    final resp = await _client.get(
      Uri.parse(_repoApiUrl),
      headers: {'Accept': 'application/vnd.github+json', 'User-Agent': 'vakhtovik-player'},
    );

    if (resp.statusCode != 200) {
      throw Exception('GitHub API: ${resp.statusCode}');
    }

    final map = jsonDecode(resp.body) as Map<String, dynamic>;
    final rawTag = (map['tag_name'] ?? '').toString().trim();
    final latest = _normalizeVersion(rawTag);
    final currentNorm = _normalizeVersion(current);
    final hasUpdate = _compareVersion(currentNorm, latest) < 0;

    String winUrl = '';
    String apkUrl = '';
    final assets = (map['assets'] as List<dynamic>? ?? const []);
    for (final a in assets) {
      final m = Map<String, dynamic>.from(a as Map);
      final name = (m['name'] ?? '').toString().toLowerCase();
      final url = (m['browser_download_url'] ?? '').toString();
      if (url.isEmpty) continue;
      if (winUrl.isEmpty && (name.contains('windows') || name.endsWith('.zip') || name.endsWith('.exe'))) {
        winUrl = url;
      }
      if (apkUrl.isEmpty && name.endsWith('.apk')) {
        apkUrl = url;
      }
    }

    return AppUpdateInfo(
      hasUpdate: hasUpdate,
      currentVersion: currentNorm,
      latestVersion: latest,
      htmlUrl: (map['html_url'] ?? '').toString(),
      releaseNotes: (map['body'] ?? '').toString(),
      windowsAssetUrl: winUrl,
      androidAssetUrl: apkUrl,
    );
  }

  static String _normalizeVersion(String v) {
    final t = v.trim();
    if (t.isEmpty) return '0.0.0';
    return t.startsWith('v') || t.startsWith('V') ? t.substring(1) : t;
    }

  static int _compareVersion(String a, String b) {
    final pa = a.split('.').map((e) => int.tryParse(e.replaceAll(RegExp(r'[^0-9]'), '')) ?? 0).toList();
    final pb = b.split('.').map((e) => int.tryParse(e.replaceAll(RegExp(r'[^0-9]'), '')) ?? 0).toList();
    final len = pa.length > pb.length ? pa.length : pb.length;
    for (var i = 0; i < len; i++) {
      final av = i < pa.length ? pa[i] : 0;
      final bv = i < pb.length ? pb[i] : 0;
      if (av != bv) return av.compareTo(bv);
    }
    return 0;
  }
}
