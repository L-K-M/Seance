import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

const _webSchemes = {'http', 'https'};

/// Keep terminal output from invoking local files or application schemes.
Future<bool> openWebLink(Uri uri) async {
  if (!_webSchemes.contains(uri.scheme) ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty) {
    return false;
  }

  try {
    return await launchUrl(uri, mode: LaunchMode.externalApplication);
  } on PlatformException {
    return false;
  } on ArgumentError {
    return false;
  }
}
