import 'package:flutter/material.dart';
import '../services/auth_service.dart';

const _green  = Color(0xFF00C853);
const _black  = Color(0xFF0D0D0D);
const _surface = Color(0xFFF4F4F4);
const _card   = Color(0xFFFFFFFF);
const _text   = Color(0xFF1A1A1A);
const _textSub = Color(0xFF666666);
const _border = Color(0xFFE0E0E0);

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
      backgroundColor: _surface,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 28),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // ── Logo ──────────────────────────────────────────────────
                Center(
                  child: Column(children: [
                    Container(
                      width: 110, height: 110,
                      decoration: BoxDecoration(
                        color: _black,
                        borderRadius: BorderRadius.circular(28),
                        border: Border.all(color: _green, width: 3),
                        boxShadow: [
                          BoxShadow(color: _green.withOpacity(0.25),
                              blurRadius: 20, spreadRadius: 2)
                        ],
                      ),
                      child: CustomPaint(painter: _OmnitrixLogoPainter()),
                    ),
                    const SizedBox(height: 18),

                    // OTN
                    Text('OTN',
                        style: TextStyle(
                          color: _green, fontSize: 12,
                          fontWeight: FontWeight.w800, letterSpacing: 6,
                        )),
                    const SizedBox(height: 4),

                    // Company name
                    const Text('Omni Trade Networks',
                        style: TextStyle(color: _text, fontSize: 22,
                            fontWeight: FontWeight.w700)),
                    const SizedBox(height: 8),

                    // Sub-app badge
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 5),
                      decoration: BoxDecoration(
                        color: _green,
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: const Text('Video Recorder',
                          style: TextStyle(color: Colors.white,
                              fontSize: 12, fontWeight: FontWeight.w600,
                              letterSpacing: 0.5)),
                    ),
                  ]),
                ),
                const SizedBox(height: 44),

                // ── Fields ────────────────────────────────────────────────
                _field(controller: _emailCtrl, hint: 'Email address',
                    icon: Icons.email_outlined,
                    keyboard: TextInputType.emailAddress),
                const SizedBox(height: 12),
                _field(
                  controller: _passCtrl, hint: 'Password',
                  icon: Icons.lock_outlined, obscure: _obscure,
                  suffix: IconButton(
                    icon: Icon(_obscure
                        ? Icons.visibility_off_outlined
                        : Icons.visibility_outlined,
                        color: _textSub, size: 20),
                    onPressed: () => setState(() => _obscure = !_obscure),
                  ),
                  onSubmit: (_) => _signIn(),
                ),

                if (_error != null) ...[
                  const SizedBox(height: 10),
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 10),
                    decoration: BoxDecoration(
                      color: Colors.red.shade50,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: Colors.red.shade200),
                    ),
                    child: Text(_error!,
                        style: TextStyle(color: Colors.red.shade700,
                            fontSize: 13)),
                  ),
                ],
                const SizedBox(height: 24),

                // ── Sign In ───────────────────────────────────────────────
                SizedBox(
                  height: 52,
                  child: ElevatedButton(
                    onPressed: _loading ? null : _signIn,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _green,
                      disabledBackgroundColor: _green.withOpacity(0.4),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14)),
                      elevation: 0,
                    ),
                    child: _loading
                        ? const SizedBox(width: 22, height: 22,
                        child: CircularProgressIndicator(
                            strokeWidth: 2.5, color: Colors.white))
                        : const Text('Sign In',
                        style: TextStyle(color: Colors.white,
                            fontSize: 16, fontWeight: FontWeight.w600)),
                  ),
                ),
                const SizedBox(height: 32),

                const Text('© Omni Trade Networks',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: _textSub, fontSize: 11)),
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
      style: const TextStyle(color: _text),
      keyboardType: keyboard,
      obscureText: obscure,
      onSubmitted: onSubmit,
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: const TextStyle(color: _textSub),
        prefixIcon: Icon(icon, color: _textSub, size: 20),
        suffixIcon: suffix,
        filled: true, fillColor: _card,
        border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: const BorderSide(color: _border)),
        enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: const BorderSide(color: _border)),
        focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: const BorderSide(color: _green, width: 2)),
      ),
    );
  }
}

/// Draws the Omnitrix-inspired OTN logo:
/// A hand with a checkmark, in green on black.
class _OmnitrixLogoPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final green = Paint()
      ..color = const Color(0xFF00C853)
      ..style = PaintingStyle.fill;

    final w = size.width; final h = size.height;

    // Outer ring (Omnitrix dial ring)
    final ringPaint = Paint()
      ..color = const Color(0xFF00C853).withOpacity(0.25)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    canvas.drawCircle(Offset(w/2, h/2), w * 0.38, ringPaint);

    // Palm base
    canvas.drawRRect(
      RRect.fromRectAndRadius(
          Rect.fromLTWH(w*0.24, h*0.52, w*0.52, h*0.31),
          const Radius.circular(9)),
      green,
    );

    // 4 fingers
    for (int i = 0; i < 4; i++) {
      final fx = w * (0.26 + i * 0.14);
      final fh = i == 0 || i == 3 ? h * 0.28 : h * 0.33;
      final fy = h * 0.52 - fh + (i == 0 || i == 3 ? h * 0.04 : 0);
      canvas.drawRRect(
        RRect.fromRectAndRadius(
            Rect.fromLTWH(fx, fy, w * 0.10, fh),
            const Radius.circular(5)),
        green,
      );
    }

    // Thumb
    canvas.drawRRect(
      RRect.fromRectAndRadius(
          Rect.fromLTWH(w*0.12, h*0.56, w*0.13, h*0.09),
          const Radius.circular(5)),
      green,
    );

    // Checkmark on palm (black)
    final ck = Paint()
      ..color = const Color(0xFF0D0D0D)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.2
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final path = Path()
      ..moveTo(w*0.31, h*0.67)
      ..lineTo(w*0.43, h*0.77)
      ..lineTo(w*0.67, h*0.58);
    canvas.drawPath(path, ck);
  }

  @override bool shouldRepaint(_) => false;
}