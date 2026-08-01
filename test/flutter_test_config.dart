import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:nauterm/app/nauterm_localizations.dart';

Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  setAppLanguage(AppLanguage.english);
  final englishJson = await File('assets/i18n/en.json').readAsString();
  NautermLocalizations.current = NautermLocalizations.parse(
    const Locale('en'),
    englishJson,
  );
  await testMain();
}
