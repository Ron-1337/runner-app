import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:material_ui/material_ui.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'core/core.dart';
import 'core/store.dart';

/// The core and the store, for every page below the app.
class Services extends InheritedWidget {
  const Services({
    super.key,
    required this.core,
    required this.store,
    required super.child,
  });

  final Core core;
  final Store store;

  static Services of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<Services>()!;

  @override
  bool updateShouldNotify(Services oldWidget) =>
      core != oldWidget.core || store != oldWidget.store;
}

/// How this phone describes itself to the server and to paired computers:
/// its model (such as "iPhone 16 Pro"), system and app versions. The name is
/// only a default; the person can change it on the sign-in page. Without the
/// platform plugins (in tests) the fallbacks below are used.
Future<Map<String, Object?>> deviceInfo() async {
  final info = knownDeviceInfo();
  var osVersion = info['osVersion'];
  var appVersion = info['appVersion'];
  try {
    final plugin = DeviceInfoPlugin();
    if (Platform.isIOS) {
      final ios = await plugin.iosInfo;
      if (ios.modelName.isNotEmpty) _model = ios.modelName;
      osVersion = ios.systemVersion;
    } else if (Platform.isAndroid) {
      final android = await plugin.androidInfo;
      _model = androidModel(android.manufacturer, android.model);
      osVersion = android.version.release;
    }
  } catch (_) {}
  try {
    appVersion = versionLabel((await PackageInfo.fromPlatform()).version);
  } catch (_) {}
  return _known = {
    ...info,
    'name': deviceName(),
    'osVersion': osVersion,
    'appVersion': appVersion,
  };
}

/// What [deviceInfo] last found, or what is known without the plugins; for
/// when waiting on them is not worth it.
Map<String, Object?> knownDeviceInfo() =>
    _known ??
    {
      'name': deviceName(),
      'platform': Platform.isIOS
          ? 'ios'
          : Platform.isAndroid
          ? 'android'
          : Platform.operatingSystem,
      'osVersion': Platform.operatingSystemVersion,
      'appVersion': versionLabel('0.1.4'),
    };

Map<String, Object?>? _known;

/// This build's number and commit; Actions passes them with `--dart-define`.
const _buildNumber = String.fromEnvironment('BUILD_NUMBER', defaultValue: '0');
const _commit = String.fromEnvironment('COMMIT', defaultValue: '000000');

/// The app's version as it is shown and sent, `vX.Y.Z(B)-commit`: the
/// release [version], the build number and the commit's first six characters.
String versionLabel(String version) {
  final commit = _commit.length > 6 ? _commit.substring(0, 6) : _commit;
  return 'v${releaseVersion(version)}($_buildNumber)-$commit';
}

/// The release part of a version, `X.Y.Z`: `v0.1.2(57)-1a2b3c` and `0.1.2+4`
/// are both `0.1.2`.
String releaseVersion(String version) =>
    RegExp(r'\d+\.\d+\.\d+').firstMatch(version)?.group(0) ?? version.trim();

/// The model [deviceInfo] found, once it has run.
String? _model;

/// The default name of this phone: its model when known.
String deviceName() {
  if (_model case final model? when model.trim().isNotEmpty) return model;
  if (Platform.isIOS) return 'iPhone';
  if (Platform.isAndroid) return 'Android 手机';
  return '${Platform.localHostname} (Runner Remote)';
}

/// "Google Pixel 8" from Build.MANUFACTURER and Build.MODEL, without repeating
/// a manufacturer the model already starts with ("samsung SM-S918B").
String androidModel(String manufacturer, String model) {
  final maker = manufacturer.trim();
  final name = model.trim();
  if (maker.isEmpty || name.toLowerCase().startsWith(maker.toLowerCase())) {
    return name;
  }
  final capitalized = maker[0].toUpperCase() + maker.substring(1);
  return '$capitalized $name'.trim();
}

/// The name the person typed, tidied; empty means the default.
String cleanDeviceName(String typed) {
  final name = typed.replaceAll(RegExp(r'[\x00-\x1f\x7f]'), '').trim();
  return String.fromCharCodes(name.runes.take(64)).trim();
}

void showError(BuildContext context, Object error) {
  ScaffoldMessenger.of(
    context,
  ).showSnackBar(SnackBar(content: Text(error.toString())));
}

/// A short notice at the bottom of the screen.
void showMessage(BuildContext context, String message) =>
    showError(context, message);
