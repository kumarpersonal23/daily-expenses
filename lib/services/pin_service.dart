import 'dart:convert';
import 'dart:math';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class PinService {
  final FlutterSecureStorage storage;
  PinService({this.storage = const FlutterSecureStorage()});
  final _algorithm = Pbkdf2(
    macAlgorithm: Hmac.sha256(),
    iterations: 210000,
    bits: 256,
  );
  Future<bool> get enabled async => await storage.read(key: 'pin_hash') != null;
  Future<List<int>> _hash(String pin, List<int> salt) async =>
      (await _algorithm.deriveKey(
        secretKey: SecretKey(utf8.encode(pin)),
        nonce: salt,
      )).extractBytes();
  Future<void> set(String pin) async {
    if (!RegExp(r'^\d{6,12}$').hasMatch(pin)) {
      throw const FormatException('Use a PIN of 6–12 digits.');
    }
    final salt = List.generate(32, (_) => Random.secure().nextInt(256));
    final hash = await _hash(pin, salt);
    await storage.write(
      key: 'pin_hash',
      value: jsonEncode({
        'salt': base64Encode(salt),
        'hash': base64Encode(hash),
      }),
    );
    await storage.delete(key: 'pin_failures');
    await storage.delete(key: 'pin_retry');
  }

  Future<bool> verify(String pin) async {
    final retry = int.tryParse(await storage.read(key: 'pin_retry') ?? '') ?? 0;
    if (DateTime.now().millisecondsSinceEpoch < retry) {
      throw const FormatException('Too many attempts. Wait one minute.');
    }
    final raw = await storage.read(key: 'pin_hash');
    if (raw == null) return true;
    final data = jsonDecode(raw) as Map<String, dynamic>;
    final actual = await _hash(pin, base64Decode(data['salt'] as String));
    final expected = base64Decode(data['hash'] as String);
    var diff = expected.length ^ actual.length;
    for (var i = 0; i < actual.length && i < expected.length; i++) {
      diff |= actual[i] ^ expected[i];
    }
    if (diff == 0) {
      await storage.delete(key: 'pin_failures');
      await storage.delete(key: 'pin_retry');
      return true;
    }
    final failures =
        (int.tryParse(await storage.read(key: 'pin_failures') ?? '') ?? 0) + 1;
    await storage.write(key: 'pin_failures', value: '$failures');
    if (failures >= 5) {
      await storage.write(
        key: 'pin_retry',
        value:
            '${DateTime.now().add(const Duration(minutes: 1)).millisecondsSinceEpoch}',
      );
      await storage.delete(key: 'pin_failures');
    }
    return false;
  }

  Future<void> disable() => storage.delete(key: 'pin_hash');
}
