import 'dart:convert';
import 'package:crypto/crypto.dart';

void main() {
  final token = 'SID=123; SAPISID=abcdefg12345; HSID=456; ';
  final match = RegExp(r'\bSAPISID=([^;]+)').firstMatch(token);
  if (match != null) {
    final sapisid = match.group(1)!;
    print('SAPISID: $sapisid');
    final time = 1717400000;
    final input = '$time $sapisid https://www.youtube.com';
    final hash = sha1.convert(utf8.encode(input)).toString();
    print('Hash: $hash');
  } else {
    print('Match failed');
  }
}
