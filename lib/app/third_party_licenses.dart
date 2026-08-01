import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

const _rustLicenseAssets = <String>[
  'assets/licenses/nauterm-rust.json',
  'assets/licenses/nauterm-mosh-rust.json',
];
const _manualLicenseManifest = 'assets/licenses/manual-components.json';

bool _registered = false;

void registerNautermThirdPartyLicenses() {
  if (_registered) return;
  _registered = true;
  LicenseRegistry.addLicense(loadNautermBundledLicenses);
}

@visibleForTesting
Stream<LicenseEntry> loadNautermBundledLicenses() async* {
  for (final asset in _rustLicenseAssets) {
    try {
      final contents = await rootBundle.loadString(asset);
      yield* Stream.fromIterable(parseRustLicenseEntries(contents));
    } on Object catch (error, stackTrace) {
      _reportLicenseAssetError(asset, error, stackTrace);
    }
  }

  try {
    final manifestContents = await rootBundle.loadString(
      _manualLicenseManifest,
    );
    final manifest = jsonDecode(manifestContents) as Map<String, Object?>;
    final entries = manifest['entries'] as List<Object?>? ?? const [];
    for (final value in entries) {
      final entry = value as Map<String, Object?>;
      final packages = (entry['packages'] as List<Object?>)
          .cast<String>()
          .where((package) => package.trim().isNotEmpty)
          .toList(growable: false);
      final licenseAsset = entry['license'] as String;
      final licenseText = await rootBundle.loadString(licenseAsset);
      if (packages.isNotEmpty && licenseText.trim().isNotEmpty) {
        yield LicenseEntryWithLineBreaks(packages, licenseText);
      }
    }
  } on Object catch (error, stackTrace) {
    _reportLicenseAssetError(_manualLicenseManifest, error, stackTrace);
  }
}

@visibleForTesting
List<LicenseEntry> parseRustLicenseEntries(String contents) {
  final document = jsonDecode(contents) as Map<String, Object?>;
  final licenses = document['licenses'] as List<Object?>? ?? const [];
  final entries = <LicenseEntry>[];

  for (final value in licenses) {
    final license = value as Map<String, Object?>;
    final text = (license['text'] as String? ?? '').trim();
    final packages = <String>{};
    for (final packageValue
        in license['packages'] as List<Object?>? ?? const []) {
      final package = packageValue as Map<String, Object?>;
      final name = (package['name'] as String? ?? '').trim();
      final version = (package['version'] as String? ?? '').trim();
      if (name.isEmpty || package['source'] == null) continue;
      packages.add(version.isEmpty ? '$name (Rust)' : '$name $version (Rust)');
    }
    if (text.isNotEmpty && packages.isNotEmpty) {
      entries.add(
        LicenseEntryWithLineBreaks(packages.toList(growable: false), text),
      );
    }
  }
  return entries;
}

void _reportLicenseAssetError(
  String asset,
  Object error,
  StackTrace stackTrace,
) {
  FlutterError.reportError(
    FlutterErrorDetails(
      exception: error,
      stack: stackTrace,
      library: 'Nauterm license registry',
      context: ErrorDescription('while loading $asset'),
    ),
  );
}
