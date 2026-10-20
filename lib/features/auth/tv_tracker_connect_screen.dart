import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../core/di/injector.dart';
import '../../core/share/pair_link.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/tracker/relay/tracker_blob.dart';
import '../../core/tracker/relay/tracker_relay.dart';
import '../../core/tracker/relay/tracker_relay_crypto.dart';
import '../../core/tv/tv_back_button.dart';
import 'tv_pairing_service.dart';
import '../../l10n/l10n.dart';

class TvTrackerConnectScreen extends StatefulWidget {
  const TvTrackerConnectScreen({super.key, this.trackerId});
  final String? trackerId; // null transfers every connected phone account

  @override
  State<TvTrackerConnectScreen> createState() => _TvTrackerConnectScreenState();
}

class _TvTrackerConnectScreenState extends State<TvTrackerConnectScreen> {
  final _svc = sl<TvPairingService>();
  String? _code, _tvSecret, _nonce, _error;
  Timer? _poll;

  String get _label => switch (widget.trackerId) {
    null => 'all accounts',
    'anilist' => context.l10n.anilist,
    'mal' => context.l10n.myAnimeList,
    'simkl' => context.l10n.simkl,
    'mangabaka' => 'MangaBaka',
    _ => widget.trackerId ?? 'all accounts',
  };

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _start();
    });
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _start() async {
    try {
      _poll?.cancel();
      setState(() {
        _code = null;
        _error = null;
      });
      final r = await _svc.startPairing(
        '${Platform.isWindows ? 'Windows PC' : 'TV'} - $_label',
      );
      if (!mounted) return;
      setState(() {
        _code = r.code;
        _tvSecret = r.tvSecret;
        _nonce = r.nonce;
      });
      _poll = Timer.periodic(const Duration(seconds: 2), (_) => _tick());
    } catch (_) {
      if (mounted) setState(() => _error = "Couldn't start. Try again.");
    }
  }

  Future<void> _tick() async {
    if (_code == null) return;
    PairPoll res;
    try {
      res = await _svc.poll(_code!, _tvSecret!);
    } catch (_) {
      return;
    }
    if (!mounted) return;
    if (res.expired) {
      _poll?.cancel();
      setState(() {
        _code = null;
        _error = 'Code expired. Get a new code.';
      });
      return;
    }
    if (!res.approved) return;
    _poll?.cancel();
    final ok = await _apply(res.trackerBlob);
    if (!mounted) return;
    if (ok) {
      Navigator.of(context).maybePop(true);
    } else {
      setState(() => _error = "Couldn't read the tracker. Try again.");
    }
  }

  Future<bool> _apply(String? blob) async {
    final nonce = _nonce;
    if (blob == null || blob.isEmpty || nonce == null) return false;
    try {
      final json = TrackerRelayCrypto.decrypt(blob, nonce);
      final applied = await sl<TrackerRelay>().unpack(TrackerBlob.decode(json));
      return widget.trackerId == null
          ? applied.isNotEmpty
          : applied.contains(widget.trackerId);
    } catch (_) {
      return false;
    }
  }

  Widget _qrOption({
    required String data,
    required String title,
    required String subtitle,
  }) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
          ),
          child: QrImageView(data: data, size: 200, gapless: true),
        ),
        const SizedBox(height: 14),
        Text(title, style: AppText.title),
        const SizedBox(height: 4),
        Text(
          subtitle,
          textAlign: TextAlign.center,
          style: AppText.body.copyWith(color: AppColors.textSecondary),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        backgroundColor: AppColors.bg,
        automaticallyImplyLeading: false,
        toolbarHeight: 72,
        titleSpacing: 8,
        title: Row(
          children: [
            const TvBackButton(),
            const SizedBox(width: 12),
            Expanded(child: Text('Connect $_label', style: AppText.headline)),
          ],
        ),
      ),
      body: SingleChildScrollView(
        child: Center(
          child: _code == null
              ? (_error != null
                    ? Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(_error!, style: AppText.body),
                          const SizedBox(height: 16),
                          OutlinedButton(
                            onPressed: _start,
                            child: const Text('Get a new code'),
                          ),
                        ],
                      )
                    : const CircularProgressIndicator())
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Wrap(
                      alignment: WrapAlignment.center,
                      spacing: 36,
                      runSpacing: 24,
                      children: [
                        // QR 1 — phone-app relay via deeplink. Opens the installed
                        // app directly so it can approve and relay this $_label
                        // session to the TV.
                        _qrOption(
                          data: PairLink.qrData(
                            code: _code!,
                            nonce: _nonce,
                            trackers: true,
                          ),
                          title: context.l10n.haveTheApp,
                          subtitle: widget.trackerId == null
                              ? 'Scan with Zangetsu on your phone and approve.\nYour linked AniList, MyAnimeList, Simkl and MangaBaka accounts transfer together.'
                              : context.l10n.openZangetsuOnYourNphoneAndScan,
                        ),
                        // QR 2 — no app needed. Opens a web page that runs the
                        // $_label login in the phone's browser and relays the token
                        // to this TV (same encrypted-blob path the poll consumes).
                        if (widget.trackerId != null &&
                            widget.trackerId != 'mangabaka')
                          _qrOption(
                            data:
                                'https://zangetsu.online/tv-connect/'
                                '?code=$_code&nonce=$_nonce&tracker=${widget.trackerId}',
                            title: context.l10n.noApp,
                            subtitle:
                                'Scan to log in with\n$_label in your browser',
                          ),
                      ],
                    ),
                    if (_error != null) ...[
                      const SizedBox(height: 16),
                      Text(
                        _error!,
                        style: AppText.caption.copyWith(
                          color: Colors.redAccent,
                        ),
                      ),
                    ],
                  ],
                ),
        ),
      ),
    );
  }
}
