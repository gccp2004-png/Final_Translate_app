import 'dart:async';

import 'package:flutter/material.dart';
import 'package:google_mlkit_language_id/google_mlkit_language_id.dart';
import 'package:google_mlkit_translation/google_mlkit_translation.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;

import 'lang_option.dart';
import 'lang_dropdown.dart';

class TranslatorScreen extends StatefulWidget {
  const TranslatorScreen({super.key});

  @override
  State<TranslatorScreen> createState() => _TranslatorScreenState();
}

class _TranslatorScreenState extends State<TranslatorScreen>
    with SingleTickerProviderStateMixin {
  LangOption _meLang = langs[0];
  LangOption _themLang = langs[1];

  String _themSaid = '';
  String _themToMe = '';
  String _meSaid = '';
  String _meToThem = '';

  bool _downloading = false;
  bool _translating = false;
  bool _sttReady = false;
  bool _listening = false;
  bool _disposed = false;
  bool _processingUtterance = false;
  bool _capturingTop = false;
  bool _autoTabActive = true;
  bool _manualListenRequested = false;

  // Keeps the Auto UI stable even when speech_to_text internally stops/restarts.
  bool _autoListeningEnabled = false;

  final _stt = stt.SpeechToText();
  final _modelManager = OnDeviceTranslatorModelManager();
  final _languageIdentifier = LanguageIdentifier(confidenceThreshold: 0.35);

  OnDeviceTranslator? _translator;
  String? _translatorKey;

  Timer? _translateDebounce;
  Timer? _autoRestartTimer;
  TabController? _tabController;

  String _liveHeardText = '';
  String _lastFinalText = '';

  @override
  void initState() {
    super.initState();

    _tabController = TabController(length: 2, vsync: this);
    _tabController!.addListener(_handleTabChange);

    _initSpeech();
    _warmUpTranslators();
  }

  void _handleTabChange() {
    if (_tabController == null) return;
    if (_tabController!.indexIsChanging) return;

    final autoActive = _tabController!.index == 0;

    if (_autoTabActive == autoActive) return;

    setState(() {
      _autoTabActive = autoActive;
    });

    if (_autoTabActive) {
      _startAutoListen();
    } else {
      _stopAllListening();
    }
  }

  void _switchTabMode(int index) {
    final autoActive = index == 0;

    if (_autoTabActive == autoActive) return;

    setState(() {
      _autoTabActive = autoActive;
    });

    if (autoActive) {
      _startAutoListen();
    } else {
      _stopAllListening();
    }
  }

  @override
  void dispose() {
    _disposed = true;

    _translateDebounce?.cancel();
    _autoRestartTimer?.cancel();

    _translator?.close();
    _languageIdentifier.close();

    _stt.stop();

    _tabController?.removeListener(_handleTabChange);
    _tabController?.dispose();

    super.dispose();
  }

  Future<void> _initSpeech() async {
    await _initSpeechToText();
  }

  Future<void> _initSpeechToText() async {
    try {
      final ok = await _stt.initialize(
        onError: (error) {
          debugPrint('STT error: $error');

          if (!mounted) return;

          setState(() {
            _listening = false;
          });

          if (_autoTabActive && _autoListeningEnabled) {
            _scheduleAutoRestart();
          } else if (_manualListenRequested) {
            _scheduleManualRestart();
          }
        },
        onStatus: (status) {
          debugPrint('STT status: $status');

          final stopped = status == 'notListening' || status == 'done';

          if (stopped) {
            if (mounted) {
              setState(() {
                _listening = false;
              });
            }

            if (_autoTabActive && _autoListeningEnabled) {
              _scheduleAutoRestart();
            } else if (_manualListenRequested) {
              _scheduleManualRestart();
            }
          }
        },
      );

      if (!mounted) return;

      setState(() {
        _sttReady = ok;
      });

      if (ok && _autoTabActive) {
        await _startAutoListen();
      }
    } catch (e) {
      debugPrint('STT init failed: $e');

      if (!mounted) return;

      setState(() {
        _sttReady = false;
        _autoListeningEnabled = false;
      });
    }
  }

  void _scheduleAutoRestart() {
    if (_disposed ||
        !_autoTabActive ||
        !_autoListeningEnabled ||
        _processingUtterance) {
      return;
    }

    _autoRestartTimer?.cancel();

    _autoRestartTimer = Timer(const Duration(milliseconds: 500), () async {
      if (_disposed ||
          !mounted ||
          !_autoTabActive ||
          !_autoListeningEnabled ||
          _listening ||
          _processingUtterance) {
        return;
      }

      await _startAutoListen();
    });
  }

  void _scheduleManualRestart() {
    if (_disposed ||
        _autoTabActive ||
        !_manualListenRequested ||
        _processingUtterance) {
      return;
    }

    final topPerson = _capturingTop;
    final completedText =
        _lastFinalText.isNotEmpty ? _lastFinalText : _liveHeardText.trim();

    _autoRestartTimer?.cancel();

    _autoRestartTimer = Timer(const Duration(seconds: 2), () async {
      if (_disposed ||
          !mounted ||
          _autoTabActive ||
          !_manualListenRequested ||
          _listening ||
          _processingUtterance) {
        return;
      }

      if (completedText.isNotEmpty) {
        await _processManualUtterance(completedText, topPerson: topPerson);

        if (!mounted || !_manualListenRequested) return;

        setState(() {
          _liveHeardText = '';
          _lastFinalText = '';
        });
      }

      await _startSpeechManualListen(topPerson: topPerson);
    });
  }

  Future<void> _stopAllListening() async {
    _manualListenRequested = false;
    _autoListeningEnabled = false;
    _autoRestartTimer?.cancel();
    _translateDebounce?.cancel();

    try {
      await _stt.stop();
    } catch (_) {}

    if (!mounted) return;

    setState(() {
      _autoListeningEnabled = false;
      _listening = false;
      _liveHeardText = '';
      _lastFinalText = '';
    });
  }

  String _norm(String s) => s.replaceAll('_', '-').toLowerCase();

  Future<List<stt.LocaleName>> _safeLocales() async {
    try {
      return await _stt.locales();
    } catch (_) {
      return const [];
    }
  }

  Future<String?> _pickLocaleFor(LangOption lang) async {
    final locales = await _safeLocales();

    final prefs = <TranslateLanguage, List<String>>{
      TranslateLanguage.english: ['en-US', 'en_US', 'en-GB', 'en_GB', 'en'],
      TranslateLanguage.spanish: ['es-ES', 'es_ES', 'es-MX', 'es_MX', 'es'],
      TranslateLanguage.hindi: ['hi-IN', 'hi_IN', 'hi'],
      TranslateLanguage.chinese: ['zh-CN', 'zh_CN', 'zh', 'cmn-Hans-CN'],
    };

    final want = prefs[lang.mlkit] ?? [lang.mlkit.bcpCode];

    if (locales.isEmpty) {
      return want.first.replaceAll('_', '-');
    }

    for (final w in want) {
      final wn = _norm(w);
      for (final l in locales) {
        if (_norm(l.localeId) == wn) return l.localeId;
      }
    }

    for (final w in want) {
      final wn = _norm(w);
      for (final l in locales) {
        if (_norm(l.localeId).startsWith(wn)) return l.localeId;
      }
    }

    final bcp = _norm(lang.mlkit.bcpCode);

    for (final l in locales) {
      if (_norm(l.localeId).startsWith(bcp)) return l.localeId;
    }

    return null;
  }

  Future<void> _startAutoListen() async {
    await _startSpeechAutoListen();
  }

  Future<void> _startSpeechAutoListen() async {
    if (_disposed || !_autoTabActive || _listening || _processingUtterance) {
      return;
    }

    if (!_sttReady) {
      await _initSpeech();
      return;
    }

    _lastFinalText = '';

    if (!mounted) return;

    setState(() {
      _autoListeningEnabled = true;
      _listening = true;
      _capturingTop = false;
      _liveHeardText = '';
    });

    try {
      await _stt.listen(
        listenMode: stt.ListenMode.dictation,
        partialResults: true,
        cancelOnError: true,
        listenFor: const Duration(seconds: 60),
        pauseFor: const Duration(seconds: 5),
        onResult: (result) {
          final words = result.recognizedWords.trim();

          if (!mounted) return;

          setState(() {
            _liveHeardText = words;
          });

          if (result.finalResult && words.isNotEmpty) {
            if (_lastFinalText == words) return;

            _lastFinalText = words;
            _translateDebounce?.cancel();

            _translateDebounce = Timer(
              const Duration(milliseconds: 150),
              () async {
                await _handleCompletedUtterance(words);
              },
            );
          }
        },
      );
    } catch (e) {
      debugPrint('Auto listen failed: $e');

      if (!mounted) return;

      setState(() {
        _listening = false;
      });

      if (_autoListeningEnabled) {
        _scheduleAutoRestart();
      }
    }
  }

  Future<void> _startManualListen({required bool topPerson}) async {
    if (_autoTabActive || _processingUtterance) return;
    if (_listening) return;

    _manualListenRequested = true;
    _autoListeningEnabled = false;

    if (!_sttReady) {
      await _initSpeech();
    }

    if (!_sttReady) return;
    if (!mounted) return;

    setState(() {
      _capturingTop = topPerson;
      _liveHeardText = '';
      _lastFinalText = '';
    });

    await _startSpeechManualListen(topPerson: topPerson);
  }

  Future<void> _startSpeechManualListen({required bool topPerson}) async {
    if (_autoTabActive || _processingUtterance) return;
    if (_listening) return;

    final speakerLang = topPerson ? _themLang : _meLang;
    final localeId = await _pickLocaleFor(speakerLang);

    _lastFinalText = '';

    if (!mounted) return;

    setState(() {
      _listening = true;
      _capturingTop = topPerson;
      _liveHeardText = '';
    });

    try {
      await _stt.listen(
        localeId: localeId,
        listenMode: stt.ListenMode.dictation,
        partialResults: true,
        cancelOnError: false,
        listenFor: const Duration(seconds: 30),
        pauseFor: const Duration(seconds: 4),
        onResult: (result) {
          final words = result.recognizedWords.trim();

          if (!mounted) return;

          setState(() {
            _liveHeardText = words;

            if (topPerson) {
              _themSaid = words;
            } else {
              _meSaid = words;
            }
          });

          if (result.finalResult && words.isNotEmpty) {
            _lastFinalText = words;
          }
        },
      );
    } catch (e) {
      debugPrint('Manual listen failed: $e');

      if (!mounted) return;

      setState(() {
        _listening = false;
      });

      if (_manualListenRequested) {
        _scheduleManualRestart();
      }
    }
  }

  Future<void> _stopManualListen() async {
    if (_autoTabActive) return;

    _manualListenRequested = false;
    _autoRestartTimer?.cancel();

    final textBeforeStop =
        _lastFinalText.isNotEmpty ? _lastFinalText : _liveHeardText.trim();

    try {
      await _stt.stop();
    } catch (_) {}

    if (!mounted) return;

    final textAfterStop =
        _lastFinalText.isNotEmpty ? _lastFinalText : _liveHeardText.trim();

    final text = textAfterStop.isNotEmpty ? textAfterStop : textBeforeStop;
    final topPerson = _capturingTop;

    setState(() {
      _listening = false;
    });

    if (text.isEmpty) {
      setState(() {
        _liveHeardText = '';
      });
      return;
    }

    await _processManualUtterance(text, topPerson: topPerson);

    if (!mounted) return;

    setState(() {
      _liveHeardText = '';
      _lastFinalText = '';
    });
  }

  Future<void> _processManualUtterance(
    String text, {
    required bool topPerson,
  }) async {
    final cleaned = text.trim();
    if (cleaned.isEmpty) return;

    if (topPerson) {
      setState(() {
        _themSaid = cleaned;
      });

      final translated = await _translateText(_themLang, _meLang, cleaned);

      if (!mounted) return;

      setState(() {
        _themToMe = translated;
      });
    } else {
      setState(() {
        _meSaid = cleaned;
      });

      final translated = await _translateText(_meLang, _themLang, cleaned);

      if (!mounted) return;

      setState(() {
        _meToThem = translated;
      });
    }
  }

  bool _languageMatches(String detectedCode, String selectedCode) {
    final detected = detectedCode.toLowerCase();
    final selected = selectedCode.toLowerCase();

    if (detected == selected) return true;

    if (detected.startsWith('$selected-')) return true;

    if (selected.startsWith('$detected-')) return true;

    if (selected == 'zh' && detected.startsWith('zh')) return true;
    if (detected == 'zh' && selected.startsWith('zh')) return true;

    if (selected.startsWith('zh') && detected.startsWith('cmn')) return true;
    if (selected.startsWith('cmn') && detected.startsWith('zh')) return true;

    return false;
  }

  Future<LangOption?> _detectRelevantLanguage(String text) async {
    final cleaned = text.trim();

    if (cleaned.isEmpty) return null;

    try {
      final possibleLanguages =
          await _languageIdentifier.identifyPossibleLanguages(cleaned);

      if (possibleLanguages.isEmpty) return null;

      final meCode = _meLang.mlkit.bcpCode.toLowerCase();
      final themCode = _themLang.mlkit.bcpCode.toLowerCase();

      double meConfidence = 0.0;
      double themConfidence = 0.0;

      for (final language in possibleLanguages) {
        final detectedCode = language.languageTag.toLowerCase();
        final confidence = language.confidence;

        if (_languageMatches(detectedCode, meCode)) {
          meConfidence = confidence;
        }

        if (_languageMatches(detectedCode, themCode)) {
          themConfidence = confidence;
        }
      }

      const minConfidence = 0.20;

      if (meConfidence < minConfidence && themConfidence < minConfidence) {
        return null;
      }

      if (meConfidence >= themConfidence) {
        return _meLang;
      }

      return _themLang;
    } catch (_) {
      return null;
    }
  }

  String _pairKey(LangOption s, LangOption t) {
    return '${s.mlkit.bcpCode}->${t.mlkit.bcpCode}';
  }

  Future<void> _ensureModelsForPair(LangOption s, LangOption t) async {
    if (mounted) {
      setState(() {
        _downloading = true;
      });
    }

    try {
      final src = s.mlkit.bcpCode;
      final tgt = t.mlkit.bcpCode;

      final srcDownloaded = await _modelManager.isModelDownloaded(src);
      final tgtDownloaded = await _modelManager.isModelDownloaded(tgt);

      if (!srcDownloaded) {
        await _modelManager.downloadModel(src);
      }

      if (!tgtDownloaded) {
        await _modelManager.downloadModel(tgt);
      }
    } finally {
      if (mounted) {
        setState(() {
          _downloading = false;
        });
      }
    }
  }

  Future<void> _ensureTranslatorForPair(LangOption s, LangOption t) async {
    final key = _pairKey(s, t);

    if (_translator != null && _translatorKey == key) {
      return;
    }

    await _ensureModelsForPair(s, t);

    await _translator?.close();

    _translator = OnDeviceTranslator(
      sourceLanguage: s.mlkit,
      targetLanguage: t.mlkit,
    );

    _translatorKey = key;
  }

  Future<String> _translateText(
    LangOption src,
    LangOption tgt,
    String text,
  ) async {
    if (text.trim().isEmpty) return '';

    if (mounted) {
      setState(() {
        _translating = true;
      });
    }

    try {
      await _ensureTranslatorForPair(src, tgt);
      return await _translator!.translateText(text);
    } catch (e) {
      return 'Error: $e';
    } finally {
      if (mounted) {
        setState(() {
          _translating = false;
        });
      }
    }
  }

  Future<void> _warmUpTranslators() async {
    try {
      await _ensureTranslatorForPair(_meLang, _themLang);
      await _ensureTranslatorForPair(_themLang, _meLang);
    } catch (_) {}
  }

  Future<void> _handleCompletedUtterance(String said) async {
    final text = said.trim();

    if (text.isEmpty || _processingUtterance) return;

    _processingUtterance = true;

    try {
      final detected = await _detectRelevantLanguage(text);

      if (!mounted) return;

      if (detected == null) {
        setState(() {
          _liveHeardText = '';
        });
        return;
      }

      if (detected.mlkit == _themLang.mlkit) {
        setState(() {
          _capturingTop = true;
          _themSaid = text;
        });

        final translated = await _translateText(_themLang, _meLang, text);

        if (!mounted) return;

        setState(() {
          _themToMe = translated;
          _liveHeardText = '';
        });
      } else if (detected.mlkit == _meLang.mlkit) {
        setState(() {
          _capturingTop = false;
          _meSaid = text;
        });

        final translated = await _translateText(_meLang, _themLang, text);

        if (!mounted) return;

        setState(() {
          _meToThem = translated;
          _liveHeardText = '';
        });
      }
    } finally {
      _processingUtterance = false;

      if (_autoTabActive && _autoListeningEnabled) {
        _scheduleAutoRestart();
      }
    }
  }

  Future<void> _changeMyLanguage(LangOption v) async {
    setState(() {
      _meLang = v;
    });

    await _warmUpTranslators();
  }

  Future<void> _changeTheirLanguage(LangOption v) async {
    setState(() {
      _themLang = v;
    });

    await _warmUpTranslators();
  }

  Widget _mirrored(bool mirrored, Widget child) {
    if (!mirrored) return child;

    return Transform(
      alignment: Alignment.center,
      transform: Matrix4.diagonal3Values(-1, 1, 1),
      child: child,
    );
  }

  Widget _tile({
    required String title,
    required String value,
    required bool mirrored,
    required Color bg,
  }) {
    return _mirrored(
      mirrored,
      ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: Container(
          color: bg,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: Colors.white.withOpacity(0.85),
                    fontSize: 12,
                    letterSpacing: 0.8,
                  ),
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: SingleChildScrollView(
                    child: Text(
                      value.isEmpty ? '—' : value,
                      softWrap: true,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _twoTilesRow({
    required Widget left,
    required Widget right,
  }) {
    return Row(
      children: [
        Expanded(child: left),
        const SizedBox(width: 10),
        Expanded(child: right),
      ],
    );
  }

  Widget _manualButton({
    required bool topPerson,
    required bool mirrored,
  }) {
    final isThisSideListening = _listening && _capturingTop == topPerson;
    final isOtherSideListening = _listening && _capturingTop != topPerson;

    final child = SizedBox(
      width: double.infinity,
      child: ElevatedButton(
        onPressed: isOtherSideListening
            ? null
            : () async {
                if (isThisSideListening) {
                  await _stopManualListen();
                } else {
                  await _startManualListen(topPerson: topPerson);
                }
              },
        style: ElevatedButton.styleFrom(
          padding: const EdgeInsets.symmetric(vertical: 14),
        ),
        child: Text(
          isThisSideListening
              ? 'Tap to Stop'
              : isOtherSideListening
                  ? 'Other side is listening'
                  : 'Tap to Start',
        ),
      ),
    );

    return _mirrored(mirrored, child);
  }

  Widget _sidePanel({
    required bool mirroredForOtherPerson,
    required String header,
    required String leftTitle,
    required String leftValue,
    required Color leftBg,
    required String rightTitle,
    required String rightValue,
    required Color rightBg,
    required bool topPerson,
    required bool showManualButton,
  }) {
    final listeningHere = _autoTabActive
        ? _autoListeningEnabled
        : _listening && _capturingTop == topPerson;

    final panel = Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.06),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  header,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: Colors.white.withOpacity(0.75),
                    fontSize: 12,
                    letterSpacing: 0.8,
                  ),
                ),
              ),
              if (listeningHere)
                Text(
                  _autoTabActive ? 'Auto Listening' : 'Active',
                  style: TextStyle(color: Colors.white.withOpacity(0.85)),
                ),
              if (!mirroredForOtherPerson && _translating) ...[
                const SizedBox(width: 10),
                const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ],
            ],
          ),
          const SizedBox(height: 10),
          Expanded(
            child: _twoTilesRow(
              left: _tile(
                title: leftTitle,
                value: leftValue,
                mirrored: false,
                bg: leftBg,
              ),
              right: _tile(
                title: rightTitle,
                value: rightValue,
                mirrored: false,
                bg: rightBg,
              ),
            ),
          ),
          if (showManualButton) ...[
            const SizedBox(height: 10),
            _manualButton(
              topPerson: topPerson,
              mirrored: mirroredForOtherPerson,
            ),
          ],
        ],
      ),
    );

    return _mirrored(mirroredForOtherPerson, panel);
  }

  Widget _buildPanels({required bool manualMode}) {
    final card = const Color(0xFF121826);
    final blue = const Color(0xFF2F6BFF);
    final green = const Color(0xFF138A5E);

    final topOrLeftPanel = _sidePanel(
      mirroredForOtherPerson: true,
      header: 'THEIR SIDE',
      leftTitle: 'THEY SAID (${_themLang.nativeLabel})',
      leftValue: _themSaid,
      leftBg: card,
      rightTitle: 'TRANSLATION FOR THEM (${_themLang.nativeLabel})',
      rightValue: _meToThem,
      rightBg: blue.withOpacity(0.75),
      topPerson: true,
      showManualButton: manualMode,
    );

    final bottomOrRightPanel = _sidePanel(
      mirroredForOtherPerson: false,
      header: 'YOUR SIDE',
      leftTitle: 'I SAID (${_meLang.englishLabel})',
      leftValue: _meSaid,
      leftBg: card,
      rightTitle: 'TRANSLATION FOR YOU (${_meLang.englishLabel})',
      rightValue: _themToMe,
      rightBg: green.withOpacity(0.75),
      topPerson: false,
      showManualButton: manualMode,
    );

    return OrientationBuilder(
      builder: (context, orientation) {
        final isPortrait = orientation == Orientation.portrait;

        return isPortrait
            ? Column(
                children: [
                  Expanded(child: topOrLeftPanel),
                  const SizedBox(height: 12),
                  Expanded(child: bottomOrRightPanel),
                ],
              )
            : Row(
                children: [
                  Expanded(child: topOrLeftPanel),
                  const SizedBox(width: 12),
                  Expanded(child: bottomOrRightPanel),
                ],
              );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final bg = const Color(0xFF0B0E14);

    return Scaffold(
      backgroundColor: bg,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            children: [
              Row(
                children: [
                  Expanded(
                    child: LangDropdown(
                      value: _meLang,
                      items: langs,
                      showBoth: true,
                      onChanged: (v) async {
                        if (v == null) return;
                        await _changeMyLanguage(v);
                      },
                    ),
                  ),
                  const SizedBox(width: 10),
                  const Icon(Icons.swap_horiz, color: Colors.white70),
                  const SizedBox(width: 10),
                  Expanded(
                    child: LangDropdown(
                      value: _themLang,
                      items: langs,
                      showBoth: true,
                      onChanged: (v) async {
                        if (v == null) return;
                        await _changeTheirLanguage(v);
                      },
                    ),
                  ),
                  const SizedBox(width: 10),
                  if (_downloading)
                    const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              Container(
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.06),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: TabBar(
                  controller: _tabController,
                  onTap: _switchTabMode,
                  indicatorColor: Colors.white,
                  labelColor: Colors.white,
                  unselectedLabelColor: Colors.white70,
                  tabs: const [
                    Tab(text: 'Auto'),
                    Tab(text: 'Manual'),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              Expanded(
                child: TabBarView(
                  controller: _tabController,
                  physics: const NeverScrollableScrollPhysics(),
                  children: [
                    _buildPanels(manualMode: false),
                    _buildPanels(manualMode: true),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}