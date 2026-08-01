// ignore_for_file: invalid_use_of_internal_member, implementation_imports

import 'package:flutter/material.dart';
import 'package:flutter/src/widgets/_window.dart';

import '../app/window_config.dart';
import '../settings/settings_app.dart';
import 'native_windowing.dart';

class SettingsWindow extends StatelessWidget {
  const SettingsWindow({super.key, required this.controller});

  final RegularWindowController controller;

  @override
  Widget build(BuildContext context) {
    return RegularWindow(
      controller: controller,
      child: const NautermSettingsApp(),
    );
  }
}

RegularWindowController createSettingsWindowController({
  required VoidCallback onDestroyed,
}) {
  return RegularWindowController(
    preferredSize: settingsWindowSize,
    preferredConstraints: const BoxConstraints(minWidth: 950, minHeight: 620),
    title: settingsWindowTitle,
    delegate: _SettingsWindowDelegate(onDestroyed: onDestroyed),
  );
}

class _SettingsWindowDelegate with RegularWindowControllerDelegate {
  _SettingsWindowDelegate({this.onDestroyed});

  final VoidCallback? onDestroyed;

  @override
  void onWindowCloseRequested(RegularWindowController controller) {
    hideSettingsNativeWindow();
    controller.destroy();
  }

  @override
  void onWindowDestroyed() {
    onDestroyed?.call();
  }
}
