import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// This phone's sign-in to a runner-server.
class Account {
  Account({
    required this.origin,
    required this.credential,
    required this.username,
  });

  final String origin;
  final String credential;
  final String username;

  Map<String, Object?> toJson() => {
    'origin': origin,
    'credential': credential,
    'username': username,
  };

  static Account fromJson(Map<String, dynamic> json) => Account(
    origin: json['origin'] as String,
    credential: json['credential'] as String,
    username: json['username'] as String? ?? '',
  );
}

/// The keys from pairing with one computer: this phone's private key for it and
/// the computer's public key, pinned with the fingerprint it had when paired.
class Pairing {
  Pairing({
    required this.clientKey,
    required this.hostKey,
    required this.fingerprint,
  });

  final String clientKey;
  final String hostKey;
  final String fingerprint;

  Map<String, Object?> toJson() => {
    'clientKey': clientKey,
    'hostKey': hostKey,
    'fingerprint': fingerprint,
  };

  static Pairing fromJson(Map<String, dynamic> json) => Pairing(
    clientKey: json['clientKey'] as String,
    hostKey: json['hostKey'] as String,
    fingerprint: json['fingerprint'] as String,
  );
}

/// Secrets live in the Keychain on iOS and in Keystore-encrypted storage on Android.
class Store {
  Store([FlutterSecureStorage? storage])
    : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;
  static const _account = 'account';
  static String _pairing(String computer) => 'pairing.$computer';

  Future<Account?> account() async {
    final text = await _storage.read(key: _account);
    return text == null ? null : Account.fromJson(jsonDecode(text));
  }

  Future<void> saveAccount(Account account) =>
      _storage.write(key: _account, value: jsonEncode(account.toJson()));

  /// Signing out forgets the account and every pairing made under it.
  Future<void> signOut() => _storage.deleteAll();

  Future<Pairing?> pairing(String computer) async {
    final text = await _storage.read(key: _pairing(computer));
    return text == null ? null : Pairing.fromJson(jsonDecode(text));
  }

  Future<void> savePairing(String computer, Pairing pairing) => _storage.write(
    key: _pairing(computer),
    value: jsonEncode(pairing.toJson()),
  );

  Future<void> forgetPairing(String computer) =>
      _storage.delete(key: _pairing(computer));
}
