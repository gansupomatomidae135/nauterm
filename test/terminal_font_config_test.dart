import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:nauterm/app/nauterm_localizations.dart';
import 'package:nauterm/terminal/terminal_config.dart';

void main() {
  test('configured CJK font precedes locale-aware system fallback', () {
    const font = TerminalFontConfig(cjkFamily: 'Sarasa Mono SC');

    expect(font.resolvedFallback(), ['Sarasa Mono SC']);
    expect(font.textStyle().fontFamilyFallback, ['Sarasa Mono SC']);
  });

  test('application language is passed to the renderer as a locale', () {
    const font = TerminalFontConfig();

    expect(
      font.resolvedLocale(language: AppLanguage.simplifiedChinese),
      const Locale('zh', 'CN'),
    );
    expect(
      font.resolvedLocale(language: AppLanguage.english),
      const Locale('en'),
    );
    expect(font.resolvedFallback(), isEmpty);
    expect(font.textStyle().fontFamilyFallback, isNull);
  });

  test('system language is used when the application follows the system', () {
    const font = TerminalFontConfig();

    expect(
      font.resolvedLocale(
        language: AppLanguage.system,
        systemLocale: const Locale('ja'),
      ),
      const Locale('ja'),
    );
  });

  test('text style carries the resolved locale to the font renderer', () {
    const font = TerminalFontConfig();
    final previousLanguage = appLanguage;
    addTearDown(() => setAppLanguage(previousLanguage));
    setAppLanguage(AppLanguage.simplifiedChinese);

    expect(font.textStyle().locale, const Locale('zh', 'CN'));
  });

  test('Windows resolves the generic monospace family to Consolas', () {
    const font = TerminalFontConfig();

    expect(font.resolvedFamily(windows: true), 'Consolas');
    expect(font.resolvedFamily(windows: false), 'monospace');
  });
}
