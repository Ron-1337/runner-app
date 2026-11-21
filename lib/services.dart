import 'dart:io';

import 'package:material_ui/material_ui.dart';

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

/// How this phone describes itself to the server and to paired computers.
Map<String, Object?> deviceInfo() {
  final platform = Platform.isIOS
      ? 'ios'
      : Platform.isAndroid
      ? 'android'
      : Platform.operatingSystem;
  return {
    'name': deviceName(),
    'platform': platform,
    'osVersion': Platform.operatingSystemVersion,
    'appVersion': '0.1.0',
  };
}

String deviceName() {
  if (Platform.isIOS) return 'iPhone';
  if (Platform.isAndroid) return 'Android 手机';
  return '${Platform.localHostname} (Runner Remote)';
}

void showError(BuildContext context, Object error) {
  ScaffoldMessenger.of(
    context,
  ).showSnackBar(SnackBar(content: Text(error.toString())));
}

/// A short notice at the bottom of the screen.
void showMessage(BuildContext context, String message) =>
    showError(context, message);
