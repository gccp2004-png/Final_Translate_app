import 'package:google_mlkit_translation/google_mlkit_translation.dart';

class LangOption {
  final String englishLabel;
  final String nativeLabel;
  final TranslateLanguage mlkit;

  const LangOption(this.englishLabel, this.nativeLabel, this.mlkit);
}

const langs = <LangOption>[
  LangOption('English', 'English', TranslateLanguage.english),
  LangOption('Spanish', 'Español', TranslateLanguage.spanish),
  LangOption('Chinese Simplified', '中文（简体）', TranslateLanguage.chinese),
  LangOption('Hindi', 'हिन्दी', TranslateLanguage.hindi),
];