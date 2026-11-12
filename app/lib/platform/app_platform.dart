// Platform capabilities for the Flutter UI.
//
// The project started as an Android app. Linux desktop keeps the same Flutter
// UI and DSH client, but several Android integrations have no desktop
// equivalent. Keep that decision in one place so pages do not grow their own
// Platform.isLinux branches.
import 'dart:io';

/// What this build can do outside the pure Flutter/Riverpod UI.
abstract final class AppPlatform {
  /// Flutter widget tests run on the host OS but must keep the Android UI
  /// assumptions their fixtures were written against.
  static bool get _isTest => Platform.environment.containsKey('FLUTTER_TEST');

  // Widget-test fixtures were written against the Android UI and plugin
  // fallbacks. Treat them as Android so those tests (and goldens) remain the
  // Android contract; only a real desktop build opens desktop branches.
  static bool get isAndroid => _isTest || Platform.isAndroid;
  static bool get isLinuxDesktop => !_isTest && Platform.isLinux;
  static bool get isMacOSDesktop => !_isTest && Platform.isMacOS;
  static bool get isWindowsDesktop => !_isTest && Platform.isWindows;
  static bool get isDesktop => isLinuxDesktop || isMacOSDesktop || isWindowsDesktop;

  /// A local DSH runtime is managed by the app through a native platform
  /// channel on Android and through a host Node process on desktop.
  static bool get supportsLocalRuntime => isAndroid || isDesktop;

  /// Android-only integrations.
  static bool get supportsPhoneControl => isAndroid;
  static bool get supportsSystemNotifications => isAndroid;
  static bool get supportsPetOverlay => isAndroid;
  static bool get supportsNativeVoice => isAndroid;
  static bool get supportsLauncherIcons => isAndroid;
  static bool get supportsAndroidBackgroundGuide => isAndroid;
  static bool get supportsAndroidSystemAccess => isAndroid;
  static bool get supportsInAppUpdate => isAndroid;

  /// webview_flutter has implementations for Android, iOS and macOS. Linux
  /// and Windows use the system browser instead.
  static bool get supportsEmbeddedWebView => isAndroid || isMacOSDesktop;

  /// mobile_scanner has no Linux or Windows implementation.
  static bool get supportsCameraScanner => !isLinuxDesktop && !isWindowsDesktop;
}
