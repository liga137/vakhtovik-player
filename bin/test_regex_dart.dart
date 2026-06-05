void main() {
  final token = '__Secure-3PSAPISID=wrong; SAPISID=correct;';
  final match = RegExp(r'\bSAPISID=([^;]+)').firstMatch(token);
  print(match?.group(1));
}
