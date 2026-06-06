import 'dart:async';
import 'dart:ui';

import 'package:firebase_analytics/firebase_analytics.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:google_generative_ai/google_generative_ai.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../config/api_keys.dart';
import '../../config/prefs_keys.dart';
import '../../models/fire_context.dart';
import '../../providers/fire_context_provider.dart';
import '../../providers/language_provider.dart';
import '../../providers/weather_context_provider.dart';
import '../../services/farm_profile_service.dart';
import '../../theme/app_theme.dart';
import '../../utils/geo_utils.dart';

// ── Message model ──────────────────────────────────────────────────────────
enum _Role { user, ai }

class _ChatMessage {
  final String text;
  final _Role role;
  final DateTime timestamp;
  final bool isError;

  const _ChatMessage({
    required this.text,
    required this.role,
    required this.timestamp,
    this.isError = false,
  });
}

// ══════════════════════════════════════════════════════════════════════════════
class AdvisorScreen extends ConsumerStatefulWidget {
  const AdvisorScreen({super.key});

  @override
  ConsumerState<AdvisorScreen> createState() => _AdvisorScreenState();
}

class _AdvisorScreenState extends ConsumerState<AdvisorScreen> {
  // ── Chat state ─────────────────────────────────────────────────────────────
  final List<_ChatMessage> _messages = [];
  final TextEditingController _inputCtrl = TextEditingController();
  final ScrollController _scrollCtrl = ScrollController();

  bool _isTyping = false;
  bool _fireCardDismissed = false;
  bool _apiKeyMissing = false;
  bool _prefsLoaded = false;

  // Farm context (SharedPreferences)
  double? _farmLat;
  double? _farmLng;
  String _crops = '';
  double _farmSize = 0;
  String _language = 'en';

  // Home screen fire cache — used when no specific fire has been tapped
  int _homeFireCount = 0;
  double? _homeNearestDistance;
  String? _homeNearestDirection;

  // Gemini
  GenerativeModel? _model;
  ChatSession? _chat;

  // Retry support
  String? _lastUserMessage;

  // Tracks which fireId triggered the last auto-send — prevents re-fires on rebuild
  String? _lastAutoFireId;

  // ── Lifecycle ──────────────────────────────────────────────────────────────
  @override
  void initState() {
    super.initState();
    _loadPrefs();
  }

  @override
  void dispose() {
    _inputCtrl.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  // ── Load SharedPreferences then init Gemini ────────────────────────────────
  Future<void> _loadPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    final profile = await FarmProfileService().loadProfile();
    if (!mounted) return;

    final lat = prefs.getDouble(PrefsKeys.farmLat);
    final lng = prefs.getDouble(PrefsKeys.farmLng);
    final language = prefs.getString(PrefsKeys.language) ?? 'en';

    // Crops and farm size live in the farm profile (Firestore or farm_profile JSON)
    final cropsList = (profile?['crops'] as List<dynamic>?)?.cast<String>() ?? [];
    final farmSize = (profile?['farmSizeAcres'] as num?)?.toDouble() ?? 0;
    final crops = cropsList.join(', ');

    final homeFireCount = prefs.getInt(PrefsKeys.homeFireCount) ?? 0;
    final homeNearestDistance = prefs.getDouble(PrefsKeys.homeNearestDistance);
    final homeNearestDirection = prefs.getString(PrefsKeys.homeNearestDirection);

    setState(() {
      _farmLat = lat;
      _farmLng = lng;
      _crops = crops.isEmpty
          ? (language == 'hi' ? 'अज्ञात फसल' : 'unknown crops')
          : crops;
      _farmSize = farmSize;
      _language = language;
      _homeFireCount = homeFireCount;
      _homeNearestDistance = homeNearestDistance;
      _homeNearestDirection = homeNearestDirection;
      _prefsLoaded = true;
    });

    FirebaseAnalytics.instance.logEvent(
      name: 'advisor_opened',
      parameters: {
        'language': language,
        'has_fire_context': ref.read(fireContextProvider) != null ? 1 : 0,
      },
    );

    _initGemini();
  }

  // ── Initialise Gemini model + chat session ─────────────────────────────────
  void _initGemini() {
    if (kGeminiApiKey.isEmpty || kGeminiApiKey == 'YOUR_GEMINI_API_KEY') {
      setState(() => _apiKeyMissing = true);
      return;
    }

    final systemPrompt = _buildSystemPrompt();

    final model = GenerativeModel(
      model: 'gemini-2.5-flash-lite',
      apiKey: kGeminiApiKey,
      systemInstruction: Content.system(systemPrompt),
    );

    setState(() {
      _model = model;
      _chat = model.startChat();
    });

    // If fire context was already set before the screen finished loading, auto-send now.
    final fireCtx = ref.read(fireContextProvider);
    if (fireCtx != null && fireCtx.fireId != _lastAutoFireId) {
      _lastAutoFireId = fireCtx.fireId;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _autoSendFireMessage(fireCtx);
      });
    }
  }

  // ── Assemble Gemini system prompt ──────────────────────────────────────────
  String _buildSystemPrompt() {
    final weather = ref.read(weatherContextProvider);
    final fireCtx = ref.read(fireContextProvider);

    final lat = _farmLat?.toStringAsFixed(4) ?? 'unknown';
    final lng = _farmLng?.toStringAsFixed(4) ?? 'unknown';
    final langName = _language == 'hi' ? 'Hindi' : 'English';

    String weatherBlock = 'Weather data not available.';
    if (weather != null) {
      weatherBlock =
          'Now: ${weather.currentTemp.round()}°C, humidity ${weather.humidity}%, '
          'wind ${weather.windSpeed.toStringAsFixed(0)} km/h ${weather.windDirection}, '
          'precip ${weather.precipMm.toStringAsFixed(1)} mm. '
          'Advisory: ${weather.summaryLineEn}';
      if (weather.forecast.isNotEmpty) {
        final lines = weather.forecast.map((d) {
          return '${DateFormat('EEE d MMM').format(d.date)}: '
              '${d.tempMin.round()}–${d.tempMax.round()}°C, '
              'rain ${d.precipMm.toStringAsFixed(1)} mm, '
              'humidity ${d.humidity}%';
        }).join(' | ');
        weatherBlock += '\n5-day forecast: $lines';
      }
    }

    String fireLine;
    if (fireCtx != null && _farmLat != null && _farmLng != null) {
      // User tapped a specific fire on the map — use precise data.
      final dir =
          bearingDirection(_farmLat!, _farmLng!, fireCtx.lat, fireCtx.lng);
      fireLine = '${fireCtx.distanceKm.toStringAsFixed(1)} km to the $dir, '
          'FRP ${fireCtx.frp.toStringAsFixed(0)} MW, '
          'detected ${DateFormat('d MMM HH:mm').format(fireCtx.detectedAt)}.';
    } else if (_homeFireCount > 0 &&
        _homeNearestDistance != null &&
        _homeNearestDirection != null) {
      // Fall back to home screen cache (updated every time Home tab loads).
      fireLine = '$_homeFireCount active fire(s) detected in the region. '
          'Nearest is ${_homeNearestDistance!.toStringAsFixed(0)} km to the '
          '$_homeNearestDirection.';
    } else {
      fireLine = 'No fires detected nearby.';
    }

    final langInstruction = _language == 'hi'
        ? 'CRITICAL INSTRUCTION: You MUST reply ONLY in Hindi (हिंदी). Use Devanagari script. Never write in English under any circumstances, even if the question is in English.'
        : 'CRITICAL INSTRUCTION: You MUST reply ONLY in English.';

    return '''You are Kheto, an agricultural advisor for Indian farmers. \
Keep answers brief (3–5 sentences max), practical, and farmer-friendly. Never use jargon.

$langInstruction

Farm location: $lat, $lng
Crops: $_crops
Farm size: ${_farmSize.toStringAsFixed(1)} acres
Weather: $weatherBlock
Nearby fire: $fireLine

You can answer questions about farming, weather, irrigation, fire safety, and crop management. \
$langInstruction
If asked about something completely unrelated to agriculture, \
politely redirect to farming topics. \
For questions requiring physical inspection, legal advice, financial advice, or medical help, \
acknowledge your limitation and refer the farmer to Krishi Vigyan Kendra (KVK) helpline: 1800-180-1551 (free call).''';
  }

  // ── Auto-send "Tell me about this fire" when arriving from Fire Map ──────────
  Future<void> _autoSendFireMessage(FireContext fireCtx) async {
    if (!mounted || _chat == null) return;
    setState(() => _fireCardDismissed = false);
    final message = _language == 'hi'
        ? 'मेरे खेत के पास इस आग के बारे में बताएं'
        : 'Tell me about this fire near my farm';
    await _sendMessage(message);
  }

  // ── Send a user message and await Gemini reply ─────────────────────────────
  Future<void> _sendMessage(String text) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty || _isTyping || _chat == null) return;

    FirebaseAnalytics.instance.logEvent(
      name: 'chatbot_message_sent',
      parameters: {
        'language': _language,
        'has_fire_context': ref.read(fireContextProvider) != null ? 1 : 0,
      },
    );

    _lastUserMessage = trimmed;
    _inputCtrl.clear();

    setState(() {
      _messages.add(_ChatMessage(
        text: trimmed,
        role: _Role.user,
        timestamp: DateTime.now(),
      ));
      _isTyping = true;
    });
    _scrollToBottom();

    try {
      final response = await _callWithBackoff(() => _chat!.sendMessage(Content.text(trimmed)));
      final reply = response.text ?? '';
      if (!mounted) return;
      setState(() {
        _messages.add(_ChatMessage(
          text: reply.isEmpty
              ? (_language == 'hi' ? 'कोई जवाब नहीं मिला।' : 'No response received.')
              : reply,
          role: _Role.ai,
          timestamp: DateTime.now(),
        ));
        _isTyping = false;
      });
    } catch (e) {
      if (!mounted) return;
      final msg = _geminiErrorMessage(e);
      setState(() {
        _messages.add(_ChatMessage(text: msg, role: _Role.ai, timestamp: DateTime.now(), isError: true));
        _isTyping = false;
      });
    }
    _scrollToBottom();
  }

  // ── Retry last message (re-sends to Gemini without adding a duplicate user bubble)
  Future<void> _retryLast() async {
    if (_lastUserMessage == null || _isTyping || _chat == null) return;
    // Remove only the last error bubble, not all of them.
    setState(() {
      final idx = _messages.lastIndexWhere((m) => m.isError);
      if (idx != -1) _messages.removeAt(idx);
      _isTyping = true;
    });
    _scrollToBottom();

    try {
      final response =
          await _callWithBackoff(() => _chat!.sendMessage(Content.text(_lastUserMessage!)));
      final reply = response.text ?? '';
      if (!mounted) return;
      setState(() {
        _messages.add(_ChatMessage(
          text: reply.isEmpty
              ? (_language == 'hi' ? 'कोई जवाब नहीं मिला।' : 'No response received.')
              : reply,
          role: _Role.ai,
          timestamp: DateTime.now(),
        ));
        _isTyping = false;
      });
    } catch (e) {
      if (!mounted) return;
      final msg = _geminiErrorMessage(e);
      setState(() {
        _messages.add(_ChatMessage(text: msg, role: _Role.ai, timestamp: DateTime.now(), isError: true));
        _isTyping = false;
      });
    }
    _scrollToBottom();
  }

  // Retries on transient 429/503 with 2s → 4s backoff. Rethrows on final failure.
  Future<T> _callWithBackoff<T>(Future<T> Function() fn) async {
    for (int attempt = 0; attempt < 3; attempt++) {
      try {
        return await fn();
      } catch (e) {
        final s = e.toString().toLowerCase();
        final retryable = s.contains('429') || s.contains('503') ||
            s.contains('resource_exhausted') || s.contains('unavailable');
        if (retryable && attempt < 2) {
          await Future.delayed(Duration(seconds: 2 << attempt)); // 2s, 4s
          continue;
        }
        rethrow;
      }
    }
    throw Exception('Max retries exceeded');
  }

  String _geminiErrorMessage(Object e) {
    final s = e.toString().toLowerCase();
    if (s.contains('429') || s.contains('quota') || s.contains('resource_exhausted')) {
      return _language == 'hi'
          ? 'API कोटा समाप्त। aistudio.google.com पर नई API key बनाएं।'
          : 'API quota exhausted. Create a new free key at aistudio.google.com.';
    }
    if (s.contains('403') || s.contains('permission') || s.contains('api_key')) {
      return _language == 'hi'
          ? 'API key अमान्य है। lib/config/api_keys.dart जांचें।'
          : 'Invalid API key. Check lib/config/api_keys.dart.';
    }
    return _language == 'hi'
        ? 'कनेक्शन त्रुटि। कृपया दोबारा कोशिश करें।'
        : 'Connection error. Please try again.';
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollCtrl.hasClients) {
        _scrollCtrl.animateTo(
          _scrollCtrl.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  // ══════════════════════════════════════════════════════════════════════════════
  // BUILD
  // ══════════════════════════════════════════════════════════════════════════════
  @override
  Widget build(BuildContext context) {
    _language = ref.watch(languageProvider);
    final fireCtx = ref.watch(fireContextProvider);
    final isHi = _language == 'hi';

    // Detect a new fire context arriving (user tapped "Ask Advisor" on Fire Map).
    ref.listen<FireContext?>(fireContextProvider, (prev, next) {
      if (next != null && next.fireId != _lastAutoFireId && _prefsLoaded) {
        setState(() {
          _lastAutoFireId = next.fireId;
          _fireCardDismissed = false;
        });
        if (_model != null) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _autoSendFireMessage(next);
          });
        }
      }
    });

    // If weather arrives after the model was created with null weather,
    // rebuild the system prompt — but only if the chat hasn't started yet.
    ref.listen<dynamic>(weatherContextProvider, (prev, next) {
      if (prev == null && next != null && _messages.isEmpty && _prefsLoaded) {
        _initGemini();
      }
    });

    final showFireCard =
        fireCtx != null && !_fireCardDismissed && !_apiKeyMissing;
    final chatIsEmpty = _messages.isEmpty && !_isTyping;

    return Container(
      color: AppTheme.bg,
      child: Column(
        children: [
          // ── Topbar ────────────────────────────────────────────────────────
          _buildTopbar(isHi),

          // ── API-key nudge (amber) — replaces chat area if key is missing ──
          if (_apiKeyMissing) _buildApiKeyNudge(isHi),

          // ── Persistent context strip (always visible when prefs loaded) ───
          if (_prefsLoaded && !_apiKeyMissing) _buildContextStrip(isHi),

          // ── Fire context card ─────────────────────────────────────────────
          if (showFireCard) _buildFireContextCard(fireCtx, isHi),

          // ── Chat + input ──────────────────────────────────────────────────
          Expanded(
            child: Column(
              children: [
                Expanded(
                  child: chatIsEmpty
                      ? _buildEmptyState(isHi)
                      : _buildChatList(isHi),
                ),
                // Quick chips: only when no messages and no typing
                if (chatIsEmpty && !_apiKeyMissing) _buildQuickChips(isHi),
                _buildInputBar(isHi),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ── Topbar ─────────────────────────────────────────────────────────────────
  Widget _buildTopbar(bool isHi) {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [AppTheme.bgTopBar, AppTheme.bg],
        ),
      ),
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 14, 18, 14),
          child: Row(
            children: [
              Text(
                isHi ? 'सलाहकार' : 'Advisor',
                style: GoogleFonts.fraunces(
                  fontSize: 21,
                  fontWeight: FontWeight.w800,
                  color: Colors.white,
                  letterSpacing: -0.02 * 21,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── Persistent context strip ───────────────────────────────────────────────
  Widget _buildContextStrip(bool isHi) {
    final weather = ref.watch(weatherContextProvider);
    final parts = <String>[];

    // Crops
    if (_crops.isNotEmpty &&
        _crops != 'unknown crops' &&
        _crops != 'अज्ञात फसल') {
      parts.add(isHi ? '🌱 $_crops' : '🌱 $_crops');
    }

    // Weather summary
    if (weather != null) {
      final summary =
          isHi ? weather.summaryLineHi : weather.summaryLineEn;
      // Take just the first clause before the dash for brevity
      final brief = summary.split('—').first.trim();
      parts.add(isHi ? '🌤 $brief' : '🌤 $brief');
    }

    if (parts.isEmpty) return const SizedBox.shrink();

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(14, 8, 14, 0),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: AppTheme.accentDark.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppTheme.accent.withValues(alpha: 0.2)),
      ),
      child: Row(
        children: [
          Icon(Icons.info_outline_rounded,
              size: 13, color: AppTheme.accent),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              parts.join('  ·  '),
              style: GoogleFonts.dmSans(
                  fontSize: 11,
                  color: AppTheme.textSub,
                  height: 1.3),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  // ── API-key missing nudge ──────────────────────────────────────────────────
  Widget _buildApiKeyNudge(bool isHi) {
    return Container(
      margin: const EdgeInsets.fromLTRB(14, 10, 14, 0),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppTheme.amberStrip,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.amberBorder),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(top: 1),
            child: Icon(Icons.warning_amber_rounded,
                color: AppTheme.amberText, size: 18),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              isHi
                  ? 'Gemini API key सेट नहीं है। lib/config/api_keys.dart में kGeminiApiKey जोड़ें।'
                  : 'Gemini API key not set. Add kGeminiApiKey in lib/config/api_keys.dart.',
              style: GoogleFonts.dmSans(
                  fontSize: 12,
                  color: AppTheme.amberText,
                  fontWeight: FontWeight.w500,
                  height: 1.4),
            ),
          ),
        ],
      ),
    );
  }

  // ── Fire context card (red-tinted, dismissible) ────────────────────────────
  Widget _buildFireContextCard(FireContext fireCtx, bool isHi) {
    final dir = (_farmLat != null && _farmLng != null)
        ? bearingDirection(_farmLat!, _farmLng!, fireCtx.lat, fireCtx.lng)
        : '?';
    final dirDisplay = isHi ? _dirHi(dir) : dir;

    return Container(
      margin: const EdgeInsets.fromLTRB(14, 10, 14, 0),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: BackdropFilter(
          // PERF: set sigmaX/Y to 0 to disable blur on budget devices
          filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
          child: Container(
            padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
            decoration: BoxDecoration(
              color: AppTheme.dangerRed.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                  color: AppTheme.dangerRed.withValues(alpha: 0.30)),
            ),
            child: Row(
              children: [
                const Icon(Icons.local_fire_department,
                    color: AppTheme.dangerRed, size: 18),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        isHi ? 'पास में आग का पता चला' : 'Fire detected nearby',
                        style: GoogleFonts.dmSans(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: AppTheme.dangerRed,
                          letterSpacing: 0.02 * 11,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        isHi
                            ? '${fireCtx.distanceKm.toStringAsFixed(1)} किमी $dirDisplay · '
                                '${fireCtx.frp.toStringAsFixed(0)} MW · '
                                '${DateFormat('d MMM HH:mm').format(fireCtx.detectedAt)}'
                            : '${fireCtx.distanceKm.toStringAsFixed(1)} km $dirDisplay · '
                                '${fireCtx.frp.toStringAsFixed(0)} MW · '
                                '${DateFormat('d MMM HH:mm').format(fireCtx.detectedAt)}',
                        style: GoogleFonts.dmSans(
                          fontSize: 12,
                          color: Colors.white.withValues(alpha: 0.70),
                          height: 1.3,
                        ),
                      ),
                    ],
                  ),
                ),
                GestureDetector(
                  onTap: () => setState(() => _fireCardDismissed = true),
                  child: Padding(
                    padding: const EdgeInsets.all(6),
                    child: Icon(Icons.close,
                        size: 16,
                        color: Colors.white.withValues(alpha: 0.40)),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ── Empty state (shown before first message) ───────────────────────────────
  Widget _buildEmptyState(bool isHi) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: AppTheme.accent.withValues(alpha: 0.08),
              border:
                  Border.all(color: AppTheme.accent.withValues(alpha: 0.20)),
            ),
            child: const Icon(Icons.chat_bubble_outline,
                size: 28, color: AppTheme.accent),
          ),
          const SizedBox(height: 14),
          Text(
            isHi ? 'अपने खेत के बारे में पूछें' : 'Ask about your farm',
            style: GoogleFonts.dmSans(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              color: Colors.white,
            ),
          ),
          const SizedBox(height: 5),
          Text(
            isHi
                ? 'आग की सुरक्षा, मौसम, और खेती की सलाह'
                : 'Fire safety, weather & farming advice',
            style: GoogleFonts.dmSans(fontSize: 12, color: AppTheme.textMuted),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  // ── Quick-question chips (empty state only) ────────────────────────────────
  Widget _buildQuickChips(bool isHi) {
    final chips = isHi
        ? [
            'क्या मेरा खेत आज सुरक्षित है?',
            'क्या अभी पराली जला सकते हैं?',
            'धुआँ दिखे तो क्या करें?',
          ]
        : [
            'Is my farm safe today?',
            'Should I burn stubble now?',
            'What to do if I see smoke?',
          ];

    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 6, 14, 8),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        alignment: WrapAlignment.center,
        children: chips.map((chip) {
          return GestureDetector(
            onTap: () => _sendMessage(chip),
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 13, vertical: 8),
              decoration: BoxDecoration(
                color: AppTheme.accent.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                    color: AppTheme.accent.withValues(alpha: 0.25)),
              ),
              child: Text(
                chip,
                style: GoogleFonts.dmSans(
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  color: AppTheme.accent,
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  // ── Chat message list ──────────────────────────────────────────────────────
  Widget _buildChatList(bool isHi) {
    return ListView.builder(
      controller: _scrollCtrl,
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
      itemCount: _messages.length + (_isTyping ? 1 : 0),
      itemBuilder: (_, i) {
        if (_isTyping && i == _messages.length) {
          return _buildTypingBubble();
        }
        final msg = _messages[i];
        return msg.role == _Role.user
            ? _buildUserBubble(msg)
            : _buildAiBubble(msg, isHi);
      },
    );
  }

  // ── User bubble (right-aligned, accent green) ──────────────────────────────
  Widget _buildUserBubble(_ChatMessage msg) {
    return Align(
      alignment: Alignment.centerRight,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 12, left: 56),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: const BoxDecoration(
                color: AppTheme.accent,
                borderRadius: BorderRadius.only(
                  topLeft: Radius.circular(16),
                  topRight: Radius.circular(4),
                  bottomLeft: Radius.circular(16),
                  bottomRight: Radius.circular(16),
                ),
              ),
              child: Text(
                msg.text,
                style: GoogleFonts.dmSans(
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                  color: AppTheme.bg,
                  height: 1.4,
                ),
              ),
            ),
            const SizedBox(height: 3),
            Text(
              _formatTime(msg.timestamp),
              style:
                  GoogleFonts.dmSans(fontSize: 10, color: AppTheme.textMuted),
            ),
          ],
        ),
      ),
    );
  }

  // ── AI bubble (left-aligned, frosted card) ─────────────────────────────────
  Widget _buildAiBubble(_ChatMessage msg, bool isHi) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 12, right: 56),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(4),
                topRight: Radius.circular(16),
                bottomLeft: Radius.circular(16),
                bottomRight: Radius.circular(16),
              ),
              child: BackdropFilter(
                // PERF: set sigmaX/Y to 0 to disable on budget devices
                filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
                child: Container(
                  padding: const EdgeInsets.fromLTRB(14, 11, 14, 11),
                  decoration: msg.isError
                      ? BoxDecoration(
                          color: AppTheme.dangerRed.withValues(alpha: 0.12),
                          border: Border.all(
                              color:
                                  AppTheme.dangerRed.withValues(alpha: 0.30)),
                        )
                      : const BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: [Color(0x2E6FCF80), Color(0x1A43A853)],
                          ),
                          border: Border.fromBorderSide(
                            BorderSide(color: Color(0x406FCF80)),
                          ),
                        ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        msg.text,
                        style: GoogleFonts.dmSans(
                          fontSize: 14,
                          fontWeight: FontWeight.w400,
                          color: Colors.white,
                          height: 1.5,
                        ),
                      ),
                      // Retry button on error messages
                      if (msg.isError) ...[
                        const SizedBox(height: 10),
                        GestureDetector(
                          onTap: _retryLast,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 12, vertical: 6),
                            decoration: BoxDecoration(
                              color:
                                  AppTheme.dangerRed.withValues(alpha: 0.18),
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(
                                  color: AppTheme.dangerRed
                                      .withValues(alpha: 0.40)),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(Icons.refresh_rounded,
                                    size: 13, color: AppTheme.dangerRed),
                                const SizedBox(width: 5),
                                Text(
                                  isHi ? 'दोबारा कोशिश करें' : 'Retry',
                                  style: GoogleFonts.dmSans(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w600,
                                    color: AppTheme.dangerRed,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: 3),
            // Timestamp + Report button row (Report is only shown for non-error AI messages
            // — satisfies Google Play's generative-AI policy: users must be able to flag
            // offensive or inaccurate AI-generated content.)
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  _formatTime(msg.timestamp),
                  style: GoogleFonts.dmSans(
                      fontSize: 10, color: AppTheme.textMuted),
                ),
                if (!msg.isError) ...[
                  const SizedBox(width: 8),
                  GestureDetector(
                    onTap: () => _confirmReportAiMessage(msg, isHi),
                    behavior: HitTestBehavior.opaque,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 2, vertical: 2),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.flag_outlined,
                            size: 11,
                            color: AppTheme.textMuted,
                          ),
                          const SizedBox(width: 3),
                          Text(
                            isHi ? 'रिपोर्ट' : 'Report',
                            style: GoogleFonts.dmSans(
                              fontSize: 10,
                              color: AppTheme.textMuted,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }

  // ── Report dialog for AI messages (Google Play generative-AI policy) ──────
  Future<void> _confirmReportAiMessage(_ChatMessage msg, bool isHi) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.bgNav,
        title: Text(
          isHi ? 'इस जवाब को रिपोर्ट करें?' : 'Report this response?',
          style: GoogleFonts.fraunces(
              color: Colors.white, fontWeight: FontWeight.w700, fontSize: 17),
        ),
        content: Text(
          isHi
              ? 'अगर यह जवाब गलत, हानिकारक, या अनुचित है तो हमें रिपोर्ट करें। हम इसकी समीक्षा करेंगे।'
              : 'If this response is incorrect, harmful, or inappropriate, report it to our team. We will review it.',
          style:
              GoogleFonts.dmSans(color: AppTheme.textSub, fontSize: 13, height: 1.4),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(
              isHi ? 'रद्द करें' : 'Cancel',
              style: GoogleFonts.dmSans(color: AppTheme.textMuted),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(
              isHi ? 'रिपोर्ट करें' : 'Report',
              style: GoogleFonts.dmSans(
                  color: AppTheme.dangerRed, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    // Log to Firebase Analytics — message snippet is truncated to 100 chars
    // because Firebase parameter values are capped at 100 characters.
    final snippet =
        msg.text.length > 100 ? msg.text.substring(0, 100) : msg.text;
    await FirebaseAnalytics.instance.logEvent(
      name: 'ai_response_reported',
      parameters: {
        'message_snippet': snippet,
        'language': _language,
        'has_fire_context': ref.read(fireContextProvider) != null ? 1 : 0,
      },
    );

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        backgroundColor: AppTheme.bgNav,
        content: Text(
          isHi
              ? 'रिपोर्ट दर्ज की गई। धन्यवाद।'
              : 'Report received. Thank you.',
          style: GoogleFonts.dmSans(color: Colors.white),
        ),
        duration: const Duration(seconds: 3),
      ),
    );
  }

  // ── Typing indicator bubble ────────────────────────────────────────────────
  Widget _buildTypingBubble() {
    return const Align(
      alignment: Alignment.centerLeft,
      child: Padding(
        padding: EdgeInsets.only(bottom: 12, right: 56),
        child: _TypingIndicator(),
      ),
    );
  }

  // ── Input bar ──────────────────────────────────────────────────────────────
  Widget _buildInputBar(bool isHi) {
    final disabled = _isTyping || _apiKeyMissing;

    return Container(
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 12),
      decoration: BoxDecoration(
        color: AppTheme.bg,
        border: Border(
          top: BorderSide(color: Colors.white.withValues(alpha: 0.06)),
        ),
      ),
      child: SafeArea(
        top: false,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            // Text field
            Expanded(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(24),
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
                  child: TextField(
                    controller: _inputCtrl,
                    enabled: !disabled,
                    style: GoogleFonts.dmSans(
                        fontSize: 14,
                        color: disabled
                            ? Colors.white.withValues(alpha: 0.35)
                            : Colors.white),
                    maxLines: 5,
                    minLines: 1,
                    textInputAction: TextInputAction.send,
                    onSubmitted: (v) => _sendMessage(v),
                    decoration: InputDecoration(
                      hintText:
                          isHi ? 'कोई सवाल पूछें…' : 'Ask a question…',
                      hintStyle: GoogleFonts.dmSans(
                          fontSize: 14, color: AppTheme.textMuted),
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 10),
                      filled: true,
                      fillColor: Colors.white.withValues(alpha: 0.05),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(24),
                        borderSide: BorderSide(
                            color: Colors.white.withValues(alpha: 0.10)),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(24),
                        borderSide: BorderSide(
                            color: Colors.white.withValues(alpha: 0.10)),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(24),
                        borderSide: const BorderSide(
                            color: AppTheme.accent, width: 1.5),
                      ),
                      disabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(24),
                        borderSide: BorderSide(
                            color: Colors.white.withValues(alpha: 0.05)),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            // Send button
            GestureDetector(
              onTap: disabled ? null : () => _sendMessage(_inputCtrl.text),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: disabled
                      ? AppTheme.accent.withValues(alpha: 0.28)
                      : AppTheme.accent,
                ),
                child: Icon(
                  Icons.send_rounded,
                  size: 18,
                  color: disabled
                      ? AppTheme.bg.withValues(alpha: 0.40)
                      : AppTheme.bg,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── Helpers ────────────────────────────────────────────────────────────────
  String _formatTime(DateTime dt) =>
      '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';

  String _dirHi(String dir) {
    const map = {
      'N': 'उत्तर',
      'NE': 'उत्तर-पूर्व',
      'E': 'पूर्व',
      'SE': 'दक्षिण-पूर्व',
      'S': 'दक्षिण',
      'SW': 'दक्षिण-पश्चिम',
      'W': 'पश्चिम',
      'NW': 'उत्तर-पश्चिम',
    };
    return map[dir] ?? dir;
  }
}

// ══════════════════════════════════════════════════════════════════════════════
// Typing indicator — three staggered pulsing dots
// ══════════════════════════════════════════════════════════════════════════════
class _TypingIndicator extends StatefulWidget {
  const _TypingIndicator();

  @override
  State<_TypingIndicator> createState() => _TypingIndicatorState();
}

class _TypingIndicatorState extends State<_TypingIndicator>
    with TickerProviderStateMixin {
  late final List<AnimationController> _controllers;
  late final List<Animation<double>> _anims;

  @override
  void initState() {
    super.initState();
    _controllers = List.generate(3, (i) {
      return AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 600),
      );
    });
    _anims = _controllers.map((c) {
      return Tween<double>(begin: 0.25, end: 1.0).animate(
        CurvedAnimation(parent: c, curve: Curves.easeInOut),
      );
    }).toList();

    // Stagger dot animations by 200 ms each
    for (int i = 0; i < 3; i++) {
      Future.delayed(Duration(milliseconds: i * 200), () {
        if (mounted) _controllers[i].repeat(reverse: true);
      });
    }
  }

  @override
  void dispose() {
    for (final c in _controllers) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: const BorderRadius.only(
        topLeft: Radius.circular(4),
        topRight: Radius.circular(16),
        bottomLeft: Radius.circular(16),
        bottomRight: Radius.circular(16),
      ),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 15),
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color(0x2E6FCF80), Color(0x1A43A853)],
            ),
            border: Border.fromBorderSide(
              BorderSide(color: Color(0x406FCF80)),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: List.generate(3, (i) {
              return Padding(
                padding: EdgeInsets.only(right: i < 2 ? 5.0 : 0),
                child: FadeTransition(
                  opacity: _anims[i],
                  child: Container(
                    width: 7,
                    height: 7,
                    decoration: const BoxDecoration(
                      shape: BoxShape.circle,
                      color: AppTheme.accent,
                    ),
                  ),
                ),
              );
            }),
          ),
        ),
      ),
    );
  }
}
