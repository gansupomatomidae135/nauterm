import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../terminal/terminal_config.dart';
import '../workspace/nauterm_workspace.dart';
import 'nauterm_theme.dart';
import 'nauterm_localizations.dart';
import 'window_config.dart';

class NautermApp extends StatelessWidget {
  const NautermApp({
    super.key,
    required this.onOpenSettings,
    this.onOpenTerminalSettings,
    this.workspaceController,
    this.onStartWindowDrag,
    this.onToggleWindowMaximized,
  });

  final VoidCallback onOpenSettings;
  final VoidCallback? onOpenTerminalSettings;
  final NautermWorkspaceController? workspaceController;
  final VoidCallback? onStartWindowDrag;
  final VoidCallback? onToggleWindowMaximized;

  @override
  Widget build(BuildContext context) {
    return ProviderScope(
      child: ValueListenableBuilder<AppLanguage>(
        valueListenable: appLanguageListenable,
        builder: (context, language, _) => ValueListenableBuilder<AppThemeMode>(
          valueListenable: appThemeModeListenable,
          builder: (context, mode, _) => MaterialApp(
            title: mainWindowTitle,
            debugShowCheckedModeBanner: false,
            locale: language.locale,
            supportedLocales: NautermLocalizations.supportedLocales,
            localizationsDelegates: const [
              NautermLocalizations.delegate,
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
            theme: nautermTheme(Brightness.light),
            darkTheme: nautermTheme(Brightness.dark),
            themeMode: mode.toFlutterThemeMode(),
            home: NautermWorkspace(
              onOpenSettings: onOpenSettings,
              onOpenTerminalSettings: onOpenTerminalSettings ?? onOpenSettings,
              controller: workspaceController,
              onStartWindowDrag: onStartWindowDrag,
              onToggleWindowMaximized: onToggleWindowMaximized,
            ),
          ),
        ),
      ),
    );
  }
}
