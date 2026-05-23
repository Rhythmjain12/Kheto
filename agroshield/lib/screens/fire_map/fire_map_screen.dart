import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_analytics/firebase_analytics.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../app_shell.dart';
import '../../config/prefs_keys.dart';
import '../../models/fire_context.dart';
import '../../providers/alert_radius_provider.dart';
import '../../providers/farm_location_provider.dart';
import '../../providers/fire_context_provider.dart';
import '../../providers/language_provider.dart';
import '../../theme/app_theme.dart';
import '../../utils/geo_utils.dart';

// ─── Internal model for a fire hotspot displayed on the map ──────────────────
class _FireHotspot {
  final String id;
  final double lat;
  final double lng;
  final double frp;
  final DateTime detectedAt;
  final double distanceKm;
  final String direction;

  const _FireHotspot({
    required this.id,
    required this.lat,
    required this.lng,
    required this.frp,
    required this.detectedAt,
    required this.distanceKm,
    required this.direction,
  });
}

// ─── Strings ──────────────────────────────────────────────────────────────────
const _s = {
  'en': {
    'title': 'Fire Map',
    'subtitle': 'NASA FIRMS hotspots',
    'last_fire': 'Last fire detected',
    'no_recent_fire': 'No fires within 200 km',
    'no_location': 'Farm location not set.\nComplete onboarding first.',
    'no_fires': 'No active fires detected\nwithin 200 km of your farm.',
    'distance': 'Distance',
    'frp': 'Fire Power',
    'detected': 'Detected',
    'ask_advisor': 'Ask Advisor about this fire',
    'km': 'km away',
    'mw': 'MW',
    'direction': 'Direction',
    'hotspot': 'Fire Hotspot',
  },
  'hi': {
    'title': 'आग का नक्शा',
    'subtitle': 'NASA FIRMS हॉटस्पॉट',
    'last_fire': 'आखिरी आग मिली',
    'no_recent_fire': '200 किमी में कोई आग नहीं',
    'no_location': 'खेत की लोकेशन नहीं मिली।\nपहले ऑनबोर्डिंग पूरी करें।',
    'no_fires': 'आपके खेत के 200 किमी में\nकोई आग नहीं मिली।',
    'distance': 'दूरी',
    'frp': 'आग की तीव्रता',
    'detected': 'पता चला',
    'ask_advisor': 'इस आग के बारे में सलाहकार से पूछें',
    'km': 'किमी दूर',
    'mw': 'MW',
    'direction': 'दिशा',
    'hotspot': 'आग का हॉटस्पॉट',
  },
};

// Maximum display radius: fires beyond this are not shown on map
const _kDisplayRadiusKm = 200.0;

// Written by main.dart notification tap handler; read by FireMapScreen to zoom.
final fireMapTargetProvider = StateProvider<LatLng?>((ref) => null);

// Written by HomeScreen fire row tap; FireMapScreen reads to auto-show info sheet.
final fireMapAutoSelectIdProvider = StateProvider<String?>((ref) => null);

class FireMapScreen extends ConsumerStatefulWidget {
  final LatLng? initialTarget;
  const FireMapScreen({super.key, this.initialTarget});

  @override
  ConsumerState<FireMapScreen> createState() => _FireMapScreenState();
}

class _FireMapScreenState extends ConsumerState<FireMapScreen> {
  GoogleMapController? _mapController;
  double? _farmLat;
  double? _farmLng;
  double _alertRadiusKm = 50;
  String _lang = 'en';

  List<_FireHotspot> _fires = [];
  StreamSubscription<QuerySnapshot>? _firesSubscription;
  bool _loading = true;
  bool _showOnlyRadius = true;
  DateTime? _lastFetchedAt;

  // Only show fires detected in the last 36 hours — older detections are
  // likely extinguished and not actionable for the farmer.
  static final _kFireAgeCutoff = const Duration(hours: 36);

  List<_FireHotspot> get _recentFires {
    final cutoff = DateTime.now().subtract(_kFireAgeCutoff);
    return _fires.where((f) => f.detectedAt.isAfter(cutoff)).toList();
  }

  List<_FireHotspot> get _displayedFires => _showOnlyRadius
      ? _recentFires.where((f) => f.distanceKm <= _alertRadiusKm).toList()
      : _recentFires;

  Map<String, String> get _str => _s[_lang] ?? _s['en']!;

  @override
  void initState() {
    super.initState();
    _loadPrefsAndSubscribe();
  }

  @override
  void dispose() {
    _firesSubscription?.cancel();
    _mapController?.dispose();
    super.dispose();
  }

  void _refresh() {
    _firesSubscription?.cancel();
    _firesSubscription = null;
    setState(() => _loading = true);
    _firesSubscription = FirebaseFirestore.instance
        .collection('fires')
        .snapshots()
        .listen(_onFiresSnapshot, onError: (_) {
      if (mounted) setState(() => _loading = false);
    });
  }

  // ── Load farm location from SharedPreferences, then subscribe to Firestore ──
  Future<void> _loadPrefsAndSubscribe() async {
    final prefs = await SharedPreferences.getInstance();
    final lat = prefs.getDouble(PrefsKeys.farmLat);
    final lng = prefs.getDouble(PrefsKeys.farmLng);
    final lang = prefs.getString(PrefsKeys.language) ?? 'en';

    if (!mounted) return;
    setState(() {
      _farmLat = lat;
      _farmLng = lng;
      _lang = lang;
      _loading = lat == null || lng == null ? false : true;
    });

    FirebaseAnalytics.instance.logEvent(
      name: 'fire_map_opened',
      parameters: {'fire_count': prefs.getInt(PrefsKeys.homeFireCount) ?? 0},
    );

    if (lat == null || lng == null) return;

    // Subscribe to Firestore fires collection
    _firesSubscription = FirebaseFirestore.instance
        .collection('fires')
        .snapshots()
        .listen(_onFiresSnapshot, onError: (_) {
      if (mounted) setState(() => _loading = false);
    });
  }

  void _onFiresSnapshot(QuerySnapshot snapshot) {
    if (!mounted) return;

    final farmLat = _farmLat!;
    final farmLng = _farmLng!;

    final List<_FireHotspot> fires = [];
    DateTime? newest;

    for (final doc in snapshot.docs) {
      final data = doc.data() as Map<String, dynamic>;
      final lat = (data['lat'] as num?)?.toDouble();
      final lng = (data['lng'] as num?)?.toDouble();
      if (lat == null || lng == null) continue;

      final dist = haversineKm(farmLat, farmLng, lat, lng);
      if (dist > _kDisplayRadiusKm) continue;

      final detectedAt =
          (data['detectedAt'] as Timestamp?)?.toDate() ?? DateTime.now();
      if (newest == null || detectedAt.isAfter(newest)) newest = detectedAt;

      fires.add(_FireHotspot(
        id: doc.id,
        lat: lat,
        lng: lng,
        frp: (data['frp'] as num?)?.toDouble() ?? 0,
        detectedAt: detectedAt,
        distanceKm: dist,
        direction: bearingDirection(farmLat, farmLng, lat, lng),
      ));
    }

    // Sort closest first
    fires.sort((a, b) => a.distanceKm.compareTo(b.distanceKm));

    setState(() {
      _fires = fires;
      _lastFetchedAt = newest;
      // Only clear loading when server-confirmed data arrives.
      // The first Firestore callback comes from the local cache (isFromCache=true)
      // and may be empty/stale; clearing _loading there caused a false
      // "No fires detected" flash before real server data arrived.
      if (!snapshot.metadata.isFromCache) _loading = false;
    });
  }

  // ── Marker colour by fire intensity (FRP) ────────────────────────────────
  BitmapDescriptor _markerForFrp(double frp) {
    if (frp >= 200) return BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueMagenta);
    if (frp >= 50)  return BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueRed);
    if (frp >= 10)  return BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueOrange);
    return BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueYellow);
  }

  String _frpLabel(double frp, String lang) {
    if (lang == 'hi') {
      if (frp >= 200) return '🔥🔥🔥🔥 भयंकर';
      if (frp >= 50)  return '🔥🔥🔥 बड़ी';
      if (frp >= 10)  return '🔥🔥 मध्यम';
      return '🔥 छोटी';
    }
    if (frp >= 200) return '🔥🔥🔥🔥 Extreme';
    if (frp >= 50)  return '🔥🔥🔥 Large';
    if (frp >= 10)  return '🔥🔥 Moderate';
    return '🔥 Small';
  }

  Color _frpColor(double frp) {
    if (frp >= 200) return Colors.pinkAccent;
    if (frp >= 50)  return AppTheme.dangerRed;
    if (frp >= 10)  return AppTheme.amberText;
    return Colors.yellow;
  }

  // ── Build marker set ──────────────────────────────────────────────────────
  Set<Marker> get _markers {
    final markers = <Marker>{};

    // Farm pin (violet — distinct from fire pins)
    if (_farmLat != null && _farmLng != null) {
      markers.add(Marker(
        markerId: const MarkerId('farm'),
        position: LatLng(_farmLat!, _farmLng!),
        icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueViolet),
        zIndexInt: 2,
      ));
    }

    // Fire markers
    for (final fire in _displayedFires) {
      markers.add(Marker(
        markerId: MarkerId(fire.id),
        position: LatLng(fire.lat, fire.lng),
        icon: _markerForFrp(fire.frp),
        zIndexInt: 1,
        onTap: () => _showFireSheet(fire),
      ));
    }

    return markers;
  }

  // ── Alert radius circle around farm ──────────────────────────────────────
  Set<Circle> get _circles {
    if (_farmLat == null || _farmLng == null) return {};
    return {
      Circle(
        circleId: const CircleId('alert_radius'),
        center: LatLng(_farmLat!, _farmLng!),
        radius: _alertRadiusKm * 1000, // metres
        strokeColor: AppTheme.accent.withValues(alpha: 0.6),
        strokeWidth: 1,
        fillColor: AppTheme.accent.withValues(alpha: 0.04),
      ),
    };
  }

  // ── Bottom sheet for a tapped fire marker ────────────────────────────────
  void _showFireSheet(_FireHotspot fire) {
    FirebaseAnalytics.instance.logEvent(
      name: 'fire_pin_tapped',
      parameters: {
        'fire_id': fire.id,
        'distance_km': fire.distanceKm.round(),
        'frp': fire.frp.round(),
      },
    );
    final str = _str;
    final distLabel =
        '${fire.distanceKm.toStringAsFixed(1)} ${str['km']}';
    final frpLabel = '${fire.frp.toStringAsFixed(1)} ${str['mw']}';
    final timeLabel = DateFormat('d MMM, h:mm a').format(fire.detectedAt.toLocal());
    final dirLabel = fire.direction;

    final intensityLabel = _frpLabel(fire.frp, _lang);
    final intensityColor = _frpColor(fire.frp);

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => _FireDetailSheet(
        distLabel: distLabel,
        frpLabel: frpLabel,
        timeLabel: timeLabel,
        dirLabel: dirLabel,
        distanceKm: fire.distanceKm,
        intensityLabel: intensityLabel,
        intensityColor: intensityColor,
        str: str,
        onAskAdvisor: () {
          Navigator.pop(context);
          // Write selected fire to provider
          ref.read(fireContextProvider.notifier).setFire(FireContext(
            fireId: fire.id,
            lat: fire.lat,
            lng: fire.lng,
            frp: fire.frp,
            distanceKm: fire.distanceKm,
            detectedAt: fire.detectedAt,
          ));
          // Switch to Advisor tab (index 3)
          ref.read(activeTabProvider.notifier).state = 3;
        },
      ),
    );
  }

  // ── Map style applied via GoogleMap.style parameter (see build) ──────────
  void _onMapCreated(GoogleMapController controller) {
    _mapController = controller;
    if (widget.initialTarget != null) {
      controller.animateCamera(CameraUpdate.newCameraPosition(
        CameraPosition(target: widget.initialTarget!, zoom: 12),
      ));
    }
  }

  void _recenterMap() {
    if (_mapController == null || _farmLat == null || _farmLng == null) return;
    _mapController!.animateCamera(CameraUpdate.newCameraPosition(
      CameraPosition(target: LatLng(_farmLat!, _farmLng!), zoom: 8.5),
    ));
  }

  @override
  Widget build(BuildContext context) {
    _lang = ref.watch(languageProvider);
    _alertRadiusKm = ref.watch(alertRadiusProvider);

    // Restart subscription when farm location changes in Settings.
    ref.listen<FarmLocation>(farmLocationProvider, (prev, next) {
      if (next.lat != null &&
          (next.lat != prev?.lat || next.lng != prev?.lng)) {
        setState(() {
          _farmLat = next.lat;
          _farmLng = next.lng;
          _fires = [];
          _loading = true;
        });
        _firesSubscription?.cancel();
        _firesSubscription = null;
        _firesSubscription = FirebaseFirestore.instance
            .collection('fires')
            .snapshots()
            .listen(_onFiresSnapshot, onError: (_) {
          if (mounted) setState(() => _loading = false);
        });
        // Re-centre map on new farm location.
        _recenterMap();
      }
    });

    // Zoom map when a notification tap delivers a fire target coordinate.
    ref.listen<LatLng?>(fireMapTargetProvider, (_, next) {
      if (next != null && _mapController != null) {
        _mapController!.animateCamera(CameraUpdate.newCameraPosition(
          CameraPosition(target: next, zoom: 12),
        ));
      }
    });

    // Auto-show info sheet when HomeScreen fire row is tapped.
    ref.listen<String?>(fireMapAutoSelectIdProvider, (_, fireId) {
      if (fireId == null) return;
      ref.read(fireMapAutoSelectIdProvider.notifier).state = null;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final matches = _fires.where((f) => f.id == fireId);
        if (matches.isNotEmpty) _showFireSheet(matches.first);
      });
    });

    return Container(
      color: AppTheme.bg,
      child: SafeArea(
        bottom: false,
        child: Column(
          children: [
            _buildTopbar(),
            Expanded(child: _buildBody()),
          ],
        ),
      ),
    );
  }

  // ── Topbar ────────────────────────────────────────────────────────────────
  Widget _buildTopbar() {
    final str = _str;
    final timeStr = _lastFetchedAt == null
        ? str['no_recent_fire']!
        : '${str['last_fire']} · ${DateFormat('d MMM, h:mm a').format(_lastFetchedAt!.toLocal())}';

    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [AppTheme.bgTopBar, AppTheme.bg],
        ),
      ),
      padding: const EdgeInsets.fromLTRB(18, 14, 18, 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  str['title']!,
                  style: GoogleFonts.fraunces(
                    fontSize: 21,
                    fontWeight: FontWeight.w800,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  timeStr,
                  style: GoogleFonts.dmSans(
                    fontSize: 12,
                    color: AppTheme.textMuted,
                  ),
                ),
              ],
            ),
          ),
          // Fire count badge
          if (_displayedFires.isNotEmpty)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: AppTheme.dangerRed.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                    color: AppTheme.dangerRed.withValues(alpha: 0.3)),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.local_fire_department,
                      size: 14, color: AppTheme.dangerRed),
                  const SizedBox(width: 4),
                  Text(
                    '${_displayedFires.length}',
                    style: GoogleFonts.dmSans(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: AppTheme.dangerRed,
                    ),
                  ),
                ],
              ),
            ),
          const SizedBox(width: 8),
          // Radius toggle
          GestureDetector(
            onTap: () => setState(() => _showOnlyRadius = !_showOnlyRadius),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: _showOnlyRadius
                        ? AppTheme.accent.withValues(alpha: 0.15)
                        : Colors.white.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                        color: _showOnlyRadius
                            ? AppTheme.accent.withValues(alpha: 0.4)
                            : Colors.white.withValues(alpha: 0.14)),
                  ),
                  child: Icon(
                    Icons.radar,
                    size: 18,
                    color: _showOnlyRadius
                        ? AppTheme.accent
                        : Colors.white.withValues(alpha: 0.5),
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  _showOnlyRadius
                      ? (_lang == 'hi' ? 'दायरा' : 'My radius')
                      : (_lang == 'hi' ? 'सभी' : 'All fires'),
                  style: GoogleFonts.dmSans(
                    fontSize: 9,
                    color: _showOnlyRadius
                        ? AppTheme.accent
                        : Colors.white.withValues(alpha: 0.4),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          // Refresh button
          GestureDetector(
            onTap: _loading ? null : _refresh,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                        color: Colors.white.withValues(alpha: 0.14)),
                  ),
                  child: _loading
                      ? const Padding(
                          padding: EdgeInsets.all(10),
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: AppTheme.accent),
                        )
                      : Icon(Icons.refresh,
                          size: 18,
                          color: Colors.white.withValues(alpha: 0.7)),
                ),
                const SizedBox(height: 3),
                Text(
                  _lang == 'hi' ? 'रीफ्रेश' : 'Refresh',
                  style: GoogleFonts.dmSans(
                    fontSize: 9,
                    color: Colors.white.withValues(alpha: 0.4),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ── Body ──────────────────────────────────────────────────────────────────
  Widget _buildBody() {
    // No farm location set
    if (_farmLat == null || _farmLng == null) {
      return _buildEmptyState(
        icon: Icons.location_off_outlined,
        message: _str['no_location']!,
        color: AppTheme.amberText,
      );
    }

    // Loading spinner
    if (_loading) {
      return const Center(
        child: CircularProgressIndicator(color: AppTheme.accent),
      );
    }

    return Stack(
      children: [
        // Full-screen Google Map
        GoogleMap(
          onMapCreated: _onMapCreated,
          initialCameraPosition: CameraPosition(
            target: LatLng(_farmLat!, _farmLng!),
            zoom: 8.5,
          ),
          markers: _markers,
          circles: _circles,
          style: _kDarkMapStyle,
          mapType: MapType.normal,
          myLocationEnabled: false,
          myLocationButtonEnabled: false,
          compassEnabled: false,
          mapToolbarEnabled: false,
          zoomControlsEnabled: false,
        ),

        // Legend overlay (bottom-left)
        Positioned(
          left: 12,
          bottom: MediaQuery.of(context).padding.bottom + 16,
          child: _buildLegend(),
        ),

        // Recenter button (bottom-right)
        Positioned(
          right: 12,
          bottom: MediaQuery.of(context).padding.bottom + 16,
          child: GestureDetector(
            onTap: _recenterMap,
            child: Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: AppTheme.bgNav.withValues(alpha: 0.9),
                shape: BoxShape.circle,
                border: Border.all(color: AppTheme.accent.withValues(alpha: 0.4)),
              ),
              child: const Icon(Icons.my_location, size: 20, color: AppTheme.accent),
            ),
          ),
        ),

        // No fires notice — slim banner at bottom, map fully accessible
        if (_fires.isEmpty && !_loading)
          Positioned(
            bottom: 100,
            left: 16,
            right: 16,
            child: IgnorePointer(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                decoration: BoxDecoration(
                  color: AppTheme.bgNav.withValues(alpha: 0.93),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: AppTheme.accent.withValues(alpha: 0.3)),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.check_circle_outline,
                        size: 16, color: AppTheme.accent),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        _str['no_fires']!,
                        textAlign: TextAlign.center,
                        style: GoogleFonts.dmSans(
                          fontSize: 13,
                          color: AppTheme.textSub,
                          height: 1.4,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }

  // ── Empty / no-data state ─────────────────────────────────────────────────
  Widget _buildEmptyState({
    required IconData icon,
    required String message,
    required Color color,
    bool opaque = true,
  }) {
    return Container(
      color: opaque ? AppTheme.bg : Colors.transparent,
      child: Center(
        child: Container(
          margin: const EdgeInsets.all(40),
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            color: AppTheme.bgNav.withValues(alpha: 0.92),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 36, color: color),
              const SizedBox(height: 12),
              Text(
                message,
                textAlign: TextAlign.center,
                style: GoogleFonts.dmSans(
                  fontSize: 14,
                  color: AppTheme.textSub,
                  height: 1.5,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── Map legend ────────────────────────────────────────────────────────────
  Widget _buildLegend() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: AppTheme.bgNav.withValues(alpha: 0.9),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          _legendRow(Colors.yellow, _lang == 'hi' ? 'छोटी' : 'Small'),
          const SizedBox(height: 4),
          _legendRow(Colors.orange, _lang == 'hi' ? 'मध्यम' : 'Moderate'),
          const SizedBox(height: 4),
          _legendRow(Colors.red, _lang == 'hi' ? 'बड़ी' : 'Large'),
          const SizedBox(height: 4),
          _legendRow(Colors.pinkAccent, _lang == 'hi' ? 'भयंकर' : 'Extreme'),
          const SizedBox(height: 4),
          _legendRow(Colors.purple, _lang == 'hi' ? 'आपका खेत' : 'Your farm'),
        ],
      ),
    );
  }

  Widget _legendRow(Color color, String label) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 6),
        Text(label,
            style: GoogleFonts.dmSans(
                fontSize: 11, color: AppTheme.textSub)),
      ],
    );
  }
}

// ─── Bottom sheet widget ──────────────────────────────────────────────────────
class _FireDetailSheet extends StatelessWidget {
  final String distLabel;
  final String frpLabel;
  final String timeLabel;
  final String dirLabel;
  final double distanceKm;
  final String intensityLabel;
  final Color intensityColor;
  final Map<String, String> str;
  final VoidCallback onAskAdvisor;

  const _FireDetailSheet({
    required this.distLabel,
    required this.frpLabel,
    required this.timeLabel,
    required this.dirLabel,
    required this.distanceKm,
    required this.intensityLabel,
    required this.intensityColor,
    required this.str,
    required this.onAskAdvisor,
  });

  Color get _threatColor {
    if (distanceKm < 25) return AppTheme.dangerRed;
    if (distanceKm < 50) return AppTheme.amberText;
    return Colors.yellow;
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppTheme.bgNav,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      padding: EdgeInsets.fromLTRB(
          20, 12, 20, MediaQuery.of(context).padding.bottom + 20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Drag handle
          Container(
            width: 36,
            height: 4,
            margin: const EdgeInsets.only(bottom: 16),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(2),
            ),
          ),

          // Threat header
          Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: _threatColor.withValues(alpha: 0.12),
                  shape: BoxShape.circle,
                  border: Border.all(color: _threatColor.withValues(alpha: 0.3)),
                ),
                child: Icon(Icons.local_fire_department,
                    size: 20, color: _threatColor),
              ),
              const SizedBox(width: 12),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(str['hotspot']!,
                      style: GoogleFonts.fraunces(
                        fontSize: 17,
                        fontWeight: FontWeight.w800,
                        color: Colors.white,
                      )),
                  const SizedBox(height: 2),
                  Text(distLabel,
                      style: GoogleFonts.dmSans(
                        fontSize: 13,
                        color: _threatColor,
                        fontWeight: FontWeight.w600,
                      )),
                  const SizedBox(height: 5),
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: intensityColor.withValues(alpha: 0.18),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                          color: intensityColor.withValues(alpha: 0.35)),
                    ),
                    child: Text(
                      intensityLabel,
                      style: GoogleFonts.dmSans(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: intensityColor),
                    ),
                  ),
                ],
              ),
            ],
          ),

          const SizedBox(height: 16),

          // Metric rows
          _metricRow(str['direction']!, dirLabel, Icons.explore_outlined),
          const SizedBox(height: 8),
          _metricRow(str['frp']!, frpLabel, Icons.bolt_outlined),
          const SizedBox(height: 8),
          _metricRow(str['detected']!, timeLabel, Icons.access_time_outlined),

          const SizedBox(height: 20),

          // Ask Advisor CTA
          GestureDetector(
            onTap: onAskAdvisor,
            child: Container(
              height: 54,
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [AppTheme.accent, AppTheme.accentDark],
                ),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.chat_bubble_outline,
                      size: 18, color: AppTheme.bg),
                  const SizedBox(width: 8),
                  Text(
                    str['ask_advisor']!,
                    style: GoogleFonts.dmSans(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      color: AppTheme.bg,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _metricRow(String label, String value, IconData icon) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
      ),
      child: Row(
        children: [
          Icon(icon, size: 16, color: AppTheme.textMuted),
          const SizedBox(width: 10),
          Text(label,
              style: GoogleFonts.dmSans(
                  fontSize: 13, color: AppTheme.textMuted)),
          const Spacer(),
          Text(value,
              style: GoogleFonts.dmSans(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: Colors.white,
              )),
        ],
      ),
    );
  }
}

// ─── Dark map style JSON ──────────────────────────────────────────────────────
// A minimal dark style that matches AppTheme.bg (#0B1A0D green-black)
const _kDarkMapStyle = '''
[
  {"elementType":"geometry","stylers":[{"color":"#0b1a0d"}]},
  {"elementType":"labels.text.fill","stylers":[{"color":"#6fcf80"}]},
  {"elementType":"labels.text.stroke","stylers":[{"color":"#0b1a0d"}]},
  {"featureType":"administrative","elementType":"geometry","stylers":[{"visibility":"off"}]},
  {"featureType":"administrative.country","elementType":"labels.text.fill","stylers":[{"color":"#9e9e9e"}]},
  {"featureType":"administrative.locality","elementType":"labels.text.fill","stylers":[{"color":"#bdbdbd"}]},
  {"featureType":"poi","stylers":[{"visibility":"off"}]},
  {"featureType":"road","elementType":"geometry","stylers":[{"color":"#1a3d1f"}]},
  {"featureType":"road","elementType":"geometry.stroke","stylers":[{"color":"#111f12"}]},
  {"featureType":"road","elementType":"labels.text.fill","stylers":[{"color":"#6fcf80"}]},
  {"featureType":"road.highway","elementType":"geometry","stylers":[{"color":"#1a5c24"}]},
  {"featureType":"transit","stylers":[{"visibility":"off"}]},
  {"featureType":"water","elementType":"geometry","stylers":[{"color":"#06110a"}]},
  {"featureType":"water","elementType":"labels.text.fill","stylers":[{"color":"#515c6d"}]}
]
''';
