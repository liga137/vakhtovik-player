import 'dart:convert';
import 'package:http/http.dart' as http;

void main() async {
  final url = 'https://www.youtube.com/';
  final headers = {
    'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
    'Accept-Language': 'ru-RU,ru;q=0.9,en-US;q=0.8,en;q=0.7',
  };

  final response = await http.get(Uri.parse(url), headers: headers);
  final html = response.body;
  
  final match = RegExp(r'var ytInitialData = (\{.*?\});</script>').firstMatch(html);
  if (match != null) {
      final jsonStr = match.group(1)!;
      print('Length: ${jsonStr.length}');
      print('Prefix: ${jsonStr.substring(0, 500)}');
  } else {
      print('No ytInitialData');
  }
}
