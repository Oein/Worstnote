// hCaptcha challenge dialog. Renders the official hCaptcha widget inside a
// WebView and resolves with the response token (or null on cancel/error).
//
// We use a tiny inline HTML page that loads the hCaptcha JS API and posts
// the token back via window.flutter_inappwebview-style postMessage —
// here, via the JS channel registered on the controller.

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../theme/notee_theme.dart';

class HCaptchaDialog extends StatefulWidget {
  const HCaptchaDialog({super.key, required this.sitekey});

  final String sitekey;

  /// Shows the captcha modal and resolves to the response token, or null.
  static Future<String?> show(BuildContext context, {required String sitekey}) {
    return showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (_) => HCaptchaDialog(sitekey: sitekey),
    );
  }

  @override
  State<HCaptchaDialog> createState() => _HCaptchaDialogState();
}

class _HCaptchaDialogState extends State<HCaptchaDialog> {
  late final WebViewController _controller;
  bool _resolved = false;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0x00000000))
      ..addJavaScriptChannel(
        'NoteeCaptcha',
        onMessageReceived: (msg) {
          if (_resolved) return;
          _resolved = true;
          if (mounted) Navigator.of(context).pop(msg.message);
        },
      )
      ..loadHtmlString(_html(widget.sitekey));
  }

  /// Tiny page hosting the hCaptcha widget. We pipe success/error/expire
  /// back through the JS channel so the Dart side can resolve the dialog.
  String _html(String sitekey) {
    return '''
<!doctype html>
<html>
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width,initial-scale=1.0" />
  <script src="https://js.hcaptcha.com/1/api.js?recaptchacompat=off" async defer></script>
  <style>
    html,body{margin:0;padding:0;background:transparent;font-family:system-ui,sans-serif;}
    .wrap{display:flex;align-items:center;justify-content:center;min-height:100vh;}
    .h-captcha{transform-origin:top center;}
  </style>
</head>
<body>
  <div class="wrap">
    <div class="h-captcha"
      data-sitekey="$sitekey"
      data-callback="onCaptchaSuccess"
      data-error-callback="onCaptchaError"
      data-expired-callback="onCaptchaExpired"></div>
  </div>
  <script>
    function onCaptchaSuccess(token) {
      window.NoteeCaptcha.postMessage(token);
    }
    function onCaptchaError(err) {
      // Don't auto-resolve; user can retry.
      console.warn('captcha error', err);
    }
    function onCaptchaExpired() {
      console.warn('captcha expired');
    }
  </script>
</body>
</html>
''';
  }

  @override
  Widget build(BuildContext context) {
    final t = NoteeProvider.of(context).tokens;
    return Dialog(
      backgroundColor: t.toolbar,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 360, maxHeight: 520),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 12, 8),
              child: Row(
                children: [
                  Text('Verify',
                      style: TextStyle(
                        fontFamily: 'Newsreader',
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                        color: t.ink,
                      )),
                  const Spacer(),
                  IconButton(
                    icon: Icon(Icons.close, color: t.inkDim, size: 20),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),
            const SizedBox(
              height: 380,
              child: _CaptchaWebViewHolder(),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}

// Separate widget so InheritedWidgets resolve cleanly. The controller is
// passed via the parent State by an InheritedWidget-less ancestor lookup
// using a static (the dialog is single-instance per show()).
class _CaptchaWebViewHolder extends StatelessWidget {
  const _CaptchaWebViewHolder();

  @override
  Widget build(BuildContext context) {
    final state = context.findAncestorStateOfType<_HCaptchaDialogState>();
    if (state == null) return const SizedBox.shrink();
    return WebViewWidget(controller: state._controller);
  }
}
