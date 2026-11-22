import 'dart:convert';
import 'dart:math';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// One sign-in of this phone to a runner-server. The phone can hold several,
/// on the same server or on different ones.
class Account {
  Account({
    required this.id,
    required this.origin,
    required this.credential,
    required this.username,
    this.serverVersion,
  });

  /// Stable for the life of the account on this phone; its pairings are kept under it.
  final String id;
  final String origin;
  final String credential;
  final String username;

  /// The version runner-server told this phone when it signed in; null for
  /// the official service, which tells none.
  final String? serverVersion;

  /// Whether this account is on the official service rather than a runner-server.
  bool get official => serverVersion == null;

  /// The server's host, for telling accounts apart.
  String get host {
    final uri = Uri.tryParse(origin);
    if (uri == null || uri.host.isEmpty) return origin;
    return uri.hasPort ? '${uri.host}:${uri.port}' : uri.host;
  }

  /// `alice@runner.example.com`, or just the host before the server named the user.
  String get label => username.isEmpty ? host : '$username@$host';

  /// Whether signing in as [username] on [origin] is this account again.
  bool sameAs(String origin, String username) =>
      sameOrigin(this.origin, origin) && this.username == username;

  /// This account signed in again, with a new credential from a server that
  /// may have changed version.
  Account signedInAgain({
    required String credential,
    required String? serverVersion,
  }) => Account(
    id: id,
    origin: origin,
    credential: credential,
    username: username,
    serverVersion: serverVersion,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'origin': origin,
    'credential': credential,
    'username': username,
    'serverVersion': serverVersion,
  };

  static Account fromJson(Map<String, dynamic> json) => Account(
    id: json['id'] as String,
    origin: json['origin'] as String,
    credential: json['credential'] as String,
    username: json['username'] as String? ?? '',
    serverVersion: json['serverVersion'] as String?,
  );
}

/// Whether two origins name the same server, ignoring case and a trailing slash.
bool sameOrigin(String a, String b) => _normal(a) == _normal(b);

String _normal(String origin) {
  var text = origin.trim().toLowerCase();
  while (text.endsWith('/')) {
    text = text.substring(0, text.length - 1);
  }
  return text;
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
///
/// `accounts` holds the list of accounts; each pairing is under
/// `pairings.<account id>.<computer id>`. Before several accounts, a single
/// `account` and `pairing.<computer id>` were stored; [accounts] moves them over.
class Store {
  Store([FlutterSecureStorage? storage])
    : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;
  static const _accounts = 'accounts';
  static const _legacyAccount = 'account';
  static const _legacyPairing = 'pairing.';
  static String _pairings(String account) => 'pairings.$account.';
  static String _pairing(String account, String computer) =>
      '${_pairings(account)}$computer';

  /// Every account, in the order they were added.
  Future<List<Account>> accounts() async {
    final text = await _storage.read(key: _accounts);
    if (text != null) {
      return [
        for (final json in jsonDecode(text) as List)
          Account.fromJson(json as Map<String, dynamic>),
      ];
    }
    return _migrate();
  }

  Future<Account?> account(String id) async {
    for (final account in await accounts()) {
      if (account.id == id) return account;
    }
    return null;
  }

  Future<List<Account>> _migrate() async {
    final legacy = await _storage.read(key: _legacyAccount);
    if (legacy == null) return [];
    final json = jsonDecode(legacy) as Map<String, dynamic>;
    final account = Account.fromJson({...json, 'id': newId()});
    // A copy: the loop deletes from the storage readAll may hand back.
    final all = (await _storage.readAll()).entries.toList();
    for (final MapEntry(:key, :value) in all) {
      if (!key.startsWith(_legacyPairing)) continue;
      final computer = key.substring(_legacyPairing.length);
      await _storage.write(key: _pairing(account.id, computer), value: value);
      await _storage.delete(key: key);
    }
    await _write([account]);
    await _storage.delete(key: _legacyAccount);
    return [account];
  }

  Future<void> _write(List<Account> accounts) => _storage.write(
    key: _accounts,
    value: jsonEncode([for (final a in accounts) a.toJson()]),
  );

  /// Saves a new sign-in. Signing in again as the same user on the same server
  /// replaces that account's credential and keeps its pairings.
  Future<Account> addAccount({
    required String origin,
    required String credential,
    required String username,
    String? serverVersion,
  }) async {
    final all = await accounts();
    final index = all.indexWhere((a) => a.sameAs(origin, username));
    final Account account;
    if (index >= 0) {
      account = all[index].signedInAgain(
        credential: credential,
        serverVersion: serverVersion,
      );
      all[index] = account;
    } else {
      account = Account(
        id: newId(),
        origin: origin,
        credential: credential,
        username: username,
        serverVersion: serverVersion,
      );
      all.add(account);
    }
    await _write(all);
    return account;
  }

  /// Forgets [account] and every pairing made under it; other accounts stay.
  Future<void> removeAccount(Account account) async {
    final all = await accounts();
    all.removeWhere((a) => a.id == account.id);
    await _write(all);
    final prefix = _pairings(account.id);
    for (final key in (await _storage.readAll()).keys.toList()) {
      if (key.startsWith(prefix)) await _storage.delete(key: key);
    }
  }

  Future<Pairing?> pairing(Account account, String computer) async {
    final text = await _storage.read(key: _pairing(account.id, computer));
    return text == null ? null : Pairing.fromJson(jsonDecode(text));
  }

  Future<void> savePairing(Account account, String computer, Pairing pairing) =>
      _storage.write(
        key: _pairing(account.id, computer),
        value: jsonEncode(pairing.toJson()),
      );

  Future<void> forgetPairing(Account account, String computer) =>
      _storage.delete(key: _pairing(account.id, computer));

  static const _fontSize = 'terminalFontSize';

  /// The terminal's font size, the same for every computer; null until changed.
  Future<double?> terminalFontSize() async =>
      double.tryParse(await _storage.read(key: _fontSize) ?? '');

  Future<void> setTerminalFontSize(double size) =>
      _storage.write(key: _fontSize, value: '$size');

  static const _enterSends = 'keyboardEnterSends';

  /// Whether the phone keyboard's return key sends (Enter) rather than
  /// starting a new line; a new line by default.
  Future<bool> keyboardEnterSends() async =>
      await _storage.read(key: _enterSends) == 'true';

  Future<void> setKeyboardEnterSends(bool sends) =>
      _storage.write(key: _enterSends, value: '$sends');
}

final _random = Random.secure();

/// A random account id: 16 hex digits, no dots, so it is safe in storage keys.
String newId() => [
  for (var i = 0; i < 8; i++)
    _random.nextInt(256).toRadixString(16).padLeft(2, '0'),
].join();
