import 'package:web/web.dart' as web;

void downloadCsv(Uri uri) {
  // The server supplies both the CSV bytes and the attachment filename.
  final anchor = web.HTMLAnchorElement()
    ..href = uri.toString()
    ..download = '';
  web.document.body!.appendChild(anchor);
  anchor.click();
  anchor.remove();
}
