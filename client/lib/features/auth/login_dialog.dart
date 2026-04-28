// Minimal login/signup dialog. Uses Notee theme fonts (Inter Tight / Newsreader).

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../theme/notee_theme.dart';
import '../sync/sync_state.dart';
import 'auth_state.dart';

class LoginDialog extends ConsumerStatefulWidget {
  const LoginDialog({super.key});

  @override
  ConsumerState<LoginDialog> createState() => _LoginDialogState();
}

class _LoginDialogState extends ConsumerState<LoginDialog> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _server = TextEditingController(text: 'https://worstnote.oein.kr');
  bool _signupMode = false;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final s = ref.read(authProvider).value;
    if (s != null) _server.text = s.serverUrl;
  }

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    _server.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() { _busy = true; _error = null; });
    try {
      await ref.read(authProvider.notifier).setServerUrl(_server.text.trim());
      final ctl = ref.read(authProvider.notifier);
      if (_signupMode) {
        await ctl.signup(_email.text.trim(), _password.text);
      } else {
        await ctl.login(_email.text.trim(), _password.text);
      }
      if (mounted) Navigator.pop(context);
      // Fire-and-forget: push all local notes after login (shows syncing indicator).
      ref.read(cloudSyncProvider.notifier).syncAll();
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = NoteeProvider.of(context).tokens;

    final labelStyle = TextStyle(
      fontFamily: 'Inter Tight',
      fontSize: 12,
      color: t.inkDim,
      fontWeight: FontWeight.w500,
    );
    final inputStyle = TextStyle(
      fontFamily: 'Inter Tight',
      fontSize: 14,
      color: t.ink,
    );
    final inputDecoration = InputDecoration(
      labelStyle: labelStyle,
      floatingLabelStyle: TextStyle(
        fontFamily: 'Inter Tight',
        fontSize: 12,
        color: t.accent,
        fontWeight: FontWeight.w500,
      ),
      enabledBorder: UnderlineInputBorder(
        borderSide: BorderSide(color: t.rule, width: 0.5),
      ),
      focusedBorder: UnderlineInputBorder(
        borderSide: BorderSide(color: t.accent, width: 1),
      ),
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(vertical: 8),
    );

    return Dialog(
      backgroundColor: t.toolbar,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 360),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                _signupMode ? 'Create account' : 'Sign in',
                style: TextStyle(
                  fontFamily: 'Newsreader',
                  fontSize: 22,
                  fontWeight: FontWeight.w600,
                  color: t.ink,
                  height: 1.2,
                ),
              ),
              const SizedBox(height: 20),
              TextField(
                controller: _server,
                style: inputStyle,
                decoration: inputDecoration.copyWith(labelText: 'Server URL'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _email,
                style: inputStyle,
                decoration: inputDecoration.copyWith(labelText: 'Email'),
                keyboardType: TextInputType.emailAddress,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _password,
                style: inputStyle,
                decoration: inputDecoration.copyWith(labelText: 'Password'),
                obscureText: true,
              ),
              const SizedBox(height: 16),
              Row(children: [
                Switch(
                  value: _signupMode,
                  activeThumbColor: t.accent,
                  onChanged: (v) => setState(() => _signupMode = v),
                ),
                const SizedBox(width: 8),
                Text(
                  _signupMode ? 'Create new account' : 'Existing account',
                  style: TextStyle(
                    fontFamily: 'Inter Tight',
                    fontSize: 13,
                    color: t.inkDim,
                  ),
                ),
              ]),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    _error!,
                    style: const TextStyle(
                      fontFamily: 'Inter Tight',
                      fontSize: 12,
                      color: Color(0xFFDC2626),
                    ),
                  ),
                ),
              const SizedBox(height: 20),
              Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                TextButton(
                  onPressed: _busy ? null : () => Navigator.pop(context),
                  child: Text(
                    'Cancel',
                    style: TextStyle(
                      fontFamily: 'Inter Tight',
                      fontSize: 13,
                      color: t.inkDim,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: t.accent,
                    foregroundColor: Colors.white,
                    textStyle: const TextStyle(
                      fontFamily: 'Inter Tight',
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                  onPressed: _busy ? null : _submit,
                  child: _busy
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : Text(_signupMode ? 'Sign up' : 'Sign in'),
                ),
              ]),
            ],
          ),
        ),
      ),
    );
  }
}
