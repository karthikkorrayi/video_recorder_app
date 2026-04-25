import 'dart:async';
import 'package:flutter/material.dart';
import 'package:connectivity_plus/connectivity_plus.dart';

/// Persistent top banner shown when device has no network at all.
/// Allow browsing cached data offline, but warn clearly.
/// Usage: wrap any screen's body with NetworkBannerWrapper.
class NetworkBannerWrapper extends StatefulWidget {
  final Widget child;
  const NetworkBannerWrapper({super.key, required this.child});

  @override
  State<NetworkBannerWrapper> createState() => _NetworkBannerWrapperState();
}

class _NetworkBannerWrapperState extends State<NetworkBannerWrapper> {
  bool _hasNetwork = true;
  StreamSubscription? _sub;

  @override
  void initState() {
    super.initState();
    _checkNow();
    _sub = Connectivity().onConnectivityChanged.listen((results) {
      final r = results.isNotEmpty ? results.first : ConnectivityResult.none;
      if (mounted) setState(() => _hasNetwork = r != ConnectivityResult.none);
    });
  }

  Future<void> _checkNow() async {
    final results = await Connectivity().checkConnectivity();
    final r = results.isNotEmpty ? results.first : ConnectivityResult.none;
    if (mounted) setState(() => _hasNetwork = r != ConnectivityResult.none);
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      // Network warning banner — only shown when offline
      AnimatedSwitcher(
        duration: const Duration(milliseconds: 300),
        child: _hasNetwork
            ? const SizedBox.shrink()
            : Container(
                key: const ValueKey('offline'),
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                    horizontal: 16, vertical: 10),
                color: const Color(0xFFE53935),
                child: const Row(children: [
                  Icon(Icons.wifi_off, color: Colors.white, size: 16),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'No network — connect to Wi-Fi or cellular to sync and upload',
                      style: TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                          fontWeight: FontWeight.w600),
                    ),
                  ),
                ]),
              ),
      ),
      Expanded(child: widget.child),
    ]);
  }
}

/// Lightweight status notifier — use anywhere to check network
class NetworkStatus extends StatefulWidget {
  final Widget Function(BuildContext context, bool hasNetwork,
      bool isWifi) builder;
  const NetworkStatus({super.key, required this.builder});

  @override
  State<NetworkStatus> createState() => _NetworkStatusState();
}

class _NetworkStatusState extends State<NetworkStatus> {
  bool _hasNetwork = true;
  bool _isWifi     = true;
  StreamSubscription? _sub;

  @override
  void initState() {
    super.initState();
    _checkNow();
    _sub = Connectivity().onConnectivityChanged.listen((results) {
      final r = results.isNotEmpty ? results.first : ConnectivityResult.none;
      if (mounted) setState(() {
        _hasNetwork = r != ConnectivityResult.none;
        _isWifi     = r == ConnectivityResult.wifi ||
                      r == ConnectivityResult.ethernet;
      });
    });
  }

  Future<void> _checkNow() async {
    final results = await Connectivity().checkConnectivity();
    final r = results.isNotEmpty ? results.first : ConnectivityResult.none;
    if (mounted) setState(() {
      _hasNetwork = r != ConnectivityResult.none;
      _isWifi     = r == ConnectivityResult.wifi ||
                    r == ConnectivityResult.ethernet;
    });
  }

  @override
  void dispose() { _sub?.cancel(); super.dispose(); }

  @override
  Widget build(BuildContext context) =>
      widget.builder(context, _hasNetwork, _isWifi);
}