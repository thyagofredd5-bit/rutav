import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../core/app_constants.dart';
import 'trip_models.dart';

/// Proveedor de LLM configurable desde la UI.
enum LlmProvider {
  gemini('Google Gemini', AppConstants.defaultGeminiModel),
  openai('OpenAI / compatible', 'gpt-4o-mini'),
  anthropic('Anthropic Claude', 'claude-haiku-5-5');

  const LlmProvider(this.label, this.defaultModel);
  final String label;
  final String defaultModel;

  static LlmProvider parse(String? raw) => LlmProvider.values.firstWhere(
        (e) => e.name == raw,
        orElse: () => LlmProvider.gemini,
      );
}

/// Ajustes persistentes (claves API incluidas, solo en almacenamiento privado
/// de la app).
class AppSettings {
  const AppSettings({
    this.provider = LlmProvider.gemini,
    this.llmApiKey = '',
    this.llmModel = '',
    this.openAiBaseUrl = 'https://api.openai.com/v1',
    this.placesApiKey = '',
    this.useWebGrounding = false,
  });

  final LlmProvider provider;
  final String llmApiKey;

  /// Vacío = usar el modelo por defecto del proveedor.
  final String llmModel;

  /// Solo para `LlmProvider.openai` (OpenRouter, DeepSeek, Groq, etc.).
  final String openAiBaseUrl;
  final String placesApiKey;

  /// Solo Gemini: investiga en Google Search en tiempo real (grounding).
  final bool useWebGrounding;

  String get effectiveModel =>
      llmModel.trim().isEmpty ? provider.defaultModel : llmModel.trim();
  bool get hasLlmKey => llmApiKey.trim().isNotEmpty;
  bool get hasPlacesKey => placesApiKey.trim().isNotEmpty;

  AppSettings copyWith({
    LlmProvider? provider,
    String? llmApiKey,
    String? llmModel,
    String? openAiBaseUrl,
    String? placesApiKey,
    bool? useWebGrounding,
  }) =>
      AppSettings(
        provider: provider ?? this.provider,
        llmApiKey: llmApiKey ?? this.llmApiKey,
        llmModel: llmModel ?? this.llmModel,
        openAiBaseUrl: openAiBaseUrl ?? this.openAiBaseUrl,
        placesApiKey: placesApiKey ?? this.placesApiKey,
        useWebGrounding: useWebGrounding ?? this.useWebGrounding,
      );

  /// "AIza••••••k9Xz" para mostrar en la UI sin exponer la clave.
  static String mask(String key) {
    final k = key.trim();
    if (k.length <= 8) return k.isEmpty ? '' : '••••';
    return '${k.substring(0, 4)}••••••${k.substring(k.length - 4)}';
  }

  Map<String, dynamic> toJson() => {
        'provider': provider.name,
        'llmApiKey': llmApiKey,
        'llmModel': llmModel,
        'openAiBaseUrl': openAiBaseUrl,
        'placesApiKey': placesApiKey,
        'useWebGrounding': useWebGrounding,
      };

  factory AppSettings.fromJson(Map<String, dynamic> j) => AppSettings(
        provider: LlmProvider.parse(j['provider'] as String?),
        llmApiKey: j['llmApiKey'] as String? ?? '',
        llmModel: j['llmModel'] as String? ?? '',
        openAiBaseUrl:
            j['openAiBaseUrl'] as String? ?? 'https://api.openai.com/v1',
        placesApiKey: j['placesApiKey'] as String? ?? '',
        useWebGrounding: j['useWebGrounding'] as bool? ?? false,
      );
}

/// Lectura/escritura de ajustes y de la última configuración de viaje.
class SettingsRepository {
  SettingsRepository(this._prefs);

  final SharedPreferences _prefs;

  AppSettings load() {
    final raw = _prefs.getString(AppConstants.prefsSettings);
    if (raw == null) return const AppSettings();
    try {
      return AppSettings.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return const AppSettings();
    }
  }

  Future<void> save(AppSettings settings) =>
      _prefs.setString(AppConstants.prefsSettings, jsonEncode(settings.toJson()));

  /// Última configuración de viaje usada (para rellenar la pantalla principal).
  TripConfig loadTripDefaults() {
    final raw = _prefs.getString(AppConstants.prefsTripDefaults);
    if (raw == null) return TripConfig.limaToArequipa;
    try {
      return TripConfig.decode(raw);
    } catch (_) {
      return TripConfig.limaToArequipa;
    }
  }

  Future<void> saveTripDefaults(TripConfig config) =>
      _prefs.setString(AppConstants.prefsTripDefaults, config.encode());
}
