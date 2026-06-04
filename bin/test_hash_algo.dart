import 'dart:convert';
import 'package:crypto/crypto.dart';

void main() {
  final t = 1717400000;
  final sapisid = '12345';
  final input = '$t $sapisid https://www.youtube.com';
  final hash = sha1.convert(utf8.encode(input)).toString();
  print('Dart Hash: $hash');
}
