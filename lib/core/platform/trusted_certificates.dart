import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Supplements an older Android trust store with Mozilla's public CA roots.
///
/// Existing platform roots remain available. This does not accept arbitrary
/// self-signed certificates or bypass certificate expiry/hostname validation.
/// Native Android clients use the same PEM via network_security_config.xml.
/// Optional context/bundle parameters keep verification tests isolated from
/// the process-wide trust store.
Future<void> installSupplementalTrustRoots({
  SecurityContext? context,
  AssetBundle? bundle,
}) async {
  final certificates = await (bundle ?? rootBundle).load(
    'android/app/src/main/res/raw/trusted_roots.pem',
  );
  (context ?? SecurityContext.defaultContext).setTrustedCertificatesBytes(
    certificates.buffer.asUint8List(
      certificates.offsetInBytes,
      certificates.lengthInBytes,
    ),
  );
  // Keep the redistributed CA data's license visible in Flutter's license UI.
  if (bundle == null) {
    LicenseRegistry.addLicense(() async* {
      yield LicenseEntryWithLineBreaks([
        'Mozilla CA certificate bundle',
      ], await rootBundle.loadString('LICENSE-MPL-2.0.txt'));
    });
  }
}
