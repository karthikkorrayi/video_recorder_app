import 'package:flutter/material.dart';
import '../services/auth_service.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _emailCtrl = TextEditingController();
  final _passCtrl  = TextEditingController();
  final _auth = AuthService();
  bool _loading = false;
  bool _obscure = true;
  String? _error;

  static const _orange  = Color(0xFFE8620A);
  static const _dark    = Color(0xFF0F0F0F);

  Future<void> _signIn() async {
    setState(() { _loading = true; _error = null; });
    try {
      await _auth.signIn(_emailCtrl.text.trim(), _passCtrl.text.trim());
    } catch (e) {
      setState(() => _error = e.toString().replaceAll('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  void dispose() {
    _emailCtrl.dispose();
    _passCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _dark,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // ── Logo ──────────────────────────────────────────────────
                Center(
                  child: Column(children: [
                    // Hand + checkmark icon
                    Container(
                      width: 100, height: 100,
                      decoration: BoxDecoration(
                        color: const Color(0xFF1C0E00),
                        borderRadius: BorderRadius.circular(26),
                        border: Border.all(color: _orange.withOpacity(0.4), width: 1.5),
                      ),
                      child: CustomPaint(painter: _HandLogoPainter()),
                    ),
                    const SizedBox(height: 18),

                    // OTN
                    const Text('OTN',
                      style: TextStyle(color: _orange, fontSize: 12,
                        fontWeight: FontWeight.w800, letterSpacing: 5)),
                    const SizedBox(height: 5),

                    // Full name
                    const Text('Omni Trade Networks',
                      style: TextStyle(color: Colors.white, fontSize: 21,
                        fontWeight: FontWeight.w700, letterSpacing: 0.2)),
                    const SizedBox(height: 8),

                    // Sub-app badge
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
                      decoration: BoxDecoration(
                        color: _orange.withOpacity(0.1),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(color: _orange.withOpacity(0.3)),
                      ),
                      child: const Text('Video Recorder',
                        style: TextStyle(color: _orange, fontSize: 12,
                          fontWeight: FontWeight.w500, letterSpacing: 0.5)),
                    ),
                  ]),
                ),
                const SizedBox(height: 44),

                // ── Fields ────────────────────────────────────────────────
                _field(controller: _emailCtrl, hint: 'Email address',
                  icon: Icons.email_outlined, keyboard: TextInputType.emailAddress),
                const SizedBox(height: 12),
                _field(
                  controller: _passCtrl, hint: 'Password',
                  icon: Icons.lock_outlined, obscure: _obscure,
                  suffix: IconButton(
                    icon: Icon(_obscure ? Icons.visibility_off_outlined : Icons.visibility_outlined,
                      color: Colors.white30, size: 20),
                    onPressed: () => setState(() => _obscure = !_obscure),
                  ),
                  onSubmit: (_) => _signIn(),
                ),

                if (_error != null) ...[
                  const SizedBox(height: 10),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                    decoration: BoxDecoration(
                      color: Colors.red.withOpacity(0.08),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: Colors.red.withOpacity(0.2)),
                    ),
                    child: Text(_error!,
                      style: const TextStyle(color: Color(0xFFFF6B6B), fontSize: 13)),
                  ),
                ],
                const SizedBox(height: 24),

                // ── Sign In ───────────────────────────────────────────────
                SizedBox(
                  height: 52,
                  child: ElevatedButton(
                    onPressed: _loading ? null : _signIn,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _orange,
                      disabledBackgroundColor: _orange.withOpacity(0.4),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                      elevation: 0,
                    ),
                    child: _loading
                      ? const SizedBox(width: 22, height: 22,
                          child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white))
                      : const Text('Sign In',
                          style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600)),
                  ),
                ),
                const SizedBox(height: 32),
                Text('© Omni Trade Networks',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.white.withOpacity(0.2), fontSize: 11, letterSpacing: 0.3)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _field({
    required TextEditingController controller,
    required String hint,
    required IconData icon,
    TextInputType? keyboard,
    bool obscure = false,
    Widget? suffix,
    void Function(String)? onSubmit,
  }) {
    return TextField(
      controller: controller,
      style: const TextStyle(color: Colors.white),
      keyboardType: keyboard,
      obscureText: obscure,
      onSubmitted: onSubmit,
      decoration: InputDecoration(
        hintText: hint, hintStyle: const TextStyle(color: Colors.white30),
        prefixIcon: Icon(icon, color: Colors.white30, size: 20),
        suffixIcon: suffix,
        filled: true, fillColor: const Color(0xFF1A1A1A),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: Color(0xFFE8620A), width: 1.5)),
      ),
    );
  }
}

/// Draws an open hand with a checkmark — task submission / activity verification symbol.
class _HandLogoPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = const Color(0xFFE8620A)
      ..style = PaintingStyle.fill;

    final w = size.width;
    final h = size.height;

    // Palm base
    final palmRect = RRect.fromRectAndRadius(
      Rect.fromLTWH(w * 0.22, h * 0.52, w * 0.56, h * 0.33),
      const Radius.circular(10),
    );
    canvas.drawRRect(palmRect, paint);

    // 4 fingers (index, middle, ring, pinky)
    final fingerW = w * 0.11;
    final fingerRadius = const Radius.circular(5);
    final fingers = [
      Rect.fromLTWH(w * 0.24, h * 0.26, fingerW, h * 0.32),
      Rect.fromLTWH(w * 0.37, h * 0.19, fingerW, h * 0.39),
      Rect.fromLTWH(w * 0.50, h * 0.19, fingerW, h * 0.39),
      Rect.fromLTWH(w * 0.63, h * 0.24, fingerW, h * 0.34),
    ];
    for (final f in fingers) {
      canvas.drawRRect(RRect.fromRectAndRadius(f, fingerRadius), paint);
    }

    // Thumb
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(w * 0.10, h * 0.56, w * 0.14, h * 0.10),
        const Radius.circular(5)),
      paint);

    // Checkmark on palm
    final ck = Paint()
      ..color = const Color(0xFF1C0E00)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.5
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    final path = Path()
      ..moveTo(w * 0.30, h * 0.68)
      ..lineTo(w * 0.43, h * 0.78)
      ..lineTo(w * 0.68, h * 0.58);
    canvas.drawPath(path, ck);
  }

  @override
  bool shouldRepaint(_) => false;
}