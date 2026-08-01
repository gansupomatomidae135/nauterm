import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import '../app/nauterm_localizations.dart';
import '../app/nauterm_theme.dart';
import '../app/window_config.dart';
import '../terminal/terminal_config.dart';
import 'settings_panel.dart';

class NautermSettingsApp extends StatelessWidget {
  const NautermSettingsApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<AppLanguage>(
      valueListenable: appLanguageListenable,
      builder: (context, language, _) => ValueListenableBuilder<AppThemeMode>(
        valueListenable: appThemeModeListenable,
        builder: (context, mode, _) => MaterialApp(
          onGenerateTitle: (context) =>
              context.tr('common.label.settings', fallback: 'Settings'),
          title: settingsWindowTitle,
          debugShowCheckedModeBanner: false,
          locale: language.locale,
          supportedLocales: NautermLocalizations.supportedLocales,
          localizationsDelegates: const [
            NautermLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          theme: settingsTheme(Brightness.light),
          darkTheme: settingsTheme(Brightness.dark),
          themeMode: mode.toFlutterThemeMode(),
          home: const SettingsPanel(),
        ),
      ),
    );
  }
}
