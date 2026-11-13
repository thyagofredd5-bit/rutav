import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../core/app_constants.dart';
import '../models/ai_town_guide.dart';
import '../models/app_settings.dart';
import '../models/town_model.dart';
import 'photo_fetcher_service.dart';

/// Error legible para mostrar en la UI.
class AiExplorerException implements Exception {
  const AiExplorerException(this.kind, this.message, {this.statusCode});
  final AiErrorKind kind;
  final String message;
  /// Código HTTP si el error vino del servidor (para la cascada de modelos).
  final int? statusCode;
  @override
  String toString() => message;
}

class LlmTestResult {
  const LlmTestResult({required this.ok, required this.message, this.latencyMs});
  final bool ok;
  final String message;
  final int? latencyMs;
}

/// Orquesta: caché local → LLM (JSON estructurado) → fotos reales → Places.
/// Todo es BAJO DEMANDA: nada se ejecuta hasta que la UI llama a [loadTownGuide].
class AiExplorerService {
  AiExplorerService({
    required SharedPreferences prefs,
    http.Client? client,
    PhotoFetcherService? photoFetcher,
  })  : _prefs = prefs,
        _client = client ?? http.Client(),
        _photos = photoFetcher ?? PhotoFetcherService(client: client);

  final SharedPreferences _prefs;
  final http.Client _client;
  final PhotoFetcherService _photos;

  // ═══════════════════════════════════════════════════════════════════════
  //  API PÚBLICA
  // ═══════════════════════════════════════════════════════════════════════

  /// Emite estados progresivos: caché inmediata (si existe) y luego ficha IA,
  /// fotos y restaurantes conforme van llegando.
  Stream<TownGuideState> loadTownGuide(
    TownModel town, {
    required AppSettings settings,
    String? tripContext,
    bool forceRefresh = false,
  }) {
    final controller = StreamController<TownGuideState>();
    _runLoad(controller, town, settings, tripContext, forceRefresh)
        .whenComplete(() {
      if (!controller.isClosed) controller.close();
    });
    return controller.stream;
  }

  Future<TownGuideState?> readCache(String townId) async {
    final raw = _prefs.getString('${AppConstants.prefsGuideCachePrefix}$townId');
    if (raw == null) return null;
    final state = TownGuideState.decodeFromCache(raw);
    if (state == null) return null;
    final at = state.cachedAt;
    if (at != null && DateTime.now().difference(at) > AppConstants.guideCacheTtl) {
      return null;
    }
    return state;
  }

  Future<void> clearCache({String? townId}) async {
    if (townId != null) {
      await _prefs.remove('${AppConstants.prefsGuideCachePrefix}$townId');
      return;
    }
    final keys = _prefs
        .getKeys()
        .where((k) => k.startsWith(AppConstants.prefsGuideCachePrefix))
        .toList();
    for (final k in keys) {
      await _prefs.remove(k);
    }
  }

  /// Cuántos pueblos hay en caché (para mostrar en Ajustes).
  int get cachedTownCount => _prefs
      .getKeys()
      .where((k) => k.startsWith(AppConstants.prefsGuideCachePrefix))
      .length;

  /// Fotos turísticas filtradas (Places → Wikipedia geosearch → Commons → zona).
  Future<List<TownPhoto>> fetchPhotos(TownModel town,
          {String placesApiKey = ''}) =>
      _photos.fetchTownPhotos(town, placesApiKey: placesApiKey);

  /// Botón "Probar conexión" de Ajustes.
  Future<LlmTestResult> testLlmConnection(AppSettings settings) async {
    if (!settings.hasLlmKey) {
      return const LlmTestResult(ok: false, message: 'Pega primero tu API Key.');
    }
    final sw = Stopwatch()..start();
    try {
      final out = await _callLlm(
        settings,
        system: 'Responde únicamente con un objeto JSON válido, sin texto adicional.',
        user: 'Devuelve exactamente: {"ok": true}',
        schema: null,
        maxTokens: 64,
        grounding: false,
      );
      sw.stop();
      final json = _extractJson(out.text);
      final ok = json['ok'] == true;
      return LlmTestResult(
        ok: ok,
        message: ok
            ? 'Conexión correcta con ${settings.provider.label} (${out.model ?? settings.effectiveModel}).'
            : 'El modelo respondió, pero con un formato inesperado.',
        latencyMs: sw.elapsedMilliseconds,
      );
    } on AiExplorerException catch (e) {
      return LlmTestResult(ok: false, message: e.message);
    } on FormatException {
      return const LlmTestResult(
          ok: false, message: 'El modelo respondió, pero no devolvió JSON válido.');
    }
  }

  Future<LlmTestResult> testPlacesKey(String apiKey) async {
    final sw = Stopwatch()..start();
    try {
      await _photos.testPlacesKey(apiKey);
      sw.stop();
      return LlmTestResult(
          ok: true,
          message: 'Google Places respondió correctamente.',
          latencyMs: sw.elapsedMilliseconds);
    } on PlacesApiException catch (e) {
      return LlmTestResult(ok: false, message: e.message);
    }
  }

  void dispose() {
    _client.close();
    _photos.dispose();
  }

  // ═══════════════════════════════════════════════════════════════════════
  //  ORQUESTACIÓN
  // ═══════════════════════════════════════════════════════════════════════

  Future<void> _runLoad(
    StreamController<TownGuideState> controller,
    TownModel town,
    AppSettings settings,
    String? tripContext,
    bool forceRefresh,
  ) async {
    var state = TownGuideState.initial(town.id);
    var dirty = false;

    void emit(TownGuideState s) {
      state = s;
      if (!controller.isClosed) controller.add(s);
    }

    Future<void> loadPhotos() async {
      emit(state.copyWith(loadingPhotos: true));
      final photos = await _photos.fetchTownPhotos(town,
          placesApiKey: settings.placesApiKey);
      if (photos.isNotEmpty) dirty = true;
      emit(state.copyWith(photos: photos, loadingPhotos: false));
    }

    Future<void> loadPlaces() async {
      emit(state.copyWith(loadingPlaces: true, clearPlacesError: true));
      try {
        final places = await _photos.fetchRestaurants(town, settings.placesApiKey);
        if (places.isNotEmpty) dirty = true;
        emit(state.copyWith(places: places, loadingPlaces: false));
      } on PlacesApiException catch (e) {
        emit(state.copyWith(loadingPlaces: false, placesError: e.message));
      }
    }

    Future<void> loadDishPhotos() async {
      final guide = state.guide;
      if (guide == null || guide.gastronomia.isEmpty) return;
      final updated = await Future.wait(guide.gastronomia.map((g) async {
        final photo = await _photos.fetchDishPhoto(g.plato);
        return photo == null ? g : g.copyWith(foto: photo);
      }));
      dirty = true;
      emit(state.copyWith(guide: guide.copyWith(gastronomia: updated)));
    }

    Future<void> loadGuide() async {
      emit(state.copyWith(loadingGuide: true, clearError: true));
      try {
        final guide = await _generateGuide(town, settings, tripContext);
        dirty = true;
        emit(state.copyWith(guide: guide, loadingGuide: false));
        await loadDishPhotos();
      } on AiExplorerException catch (e) {
        emit(state.copyWith(
            loadingGuide: false, errorKind: e.kind, errorMessage: e.message));
      }
    }

    try {
      final cached = forceRefresh ? null : await readCache(town.id);
      if (cached != null) {
        // Cero tokens y cero datos: se sirve directo desde la caché local.
        emit(cached);
        final pending = <Future<void>>[];
        if (cached.photos.isEmpty) pending.add(loadPhotos());
        if (settings.hasPlacesKey && cached.places.isEmpty) pending.add(loadPlaces());
        await Future.wait(pending);
      } else {
        emit(state.copyWith(
          loadingGuide: true,
          loadingPhotos: true,
          loadingPlaces: settings.hasPlacesKey,
        ));
        await Future.wait([
          loadGuide(),
          loadPhotos(),
          if (settings.hasPlacesKey) loadPlaces(),
        ]);
      }

      if (dirty && state.guide != null) {
        await _writeCache(town.id, state);
      }
    } catch (e) {
      emit(state.copyWith(
        loadingGuide: false,
        loadingPhotos: false,
        loadingPlaces: false,
        errorKind: AiErrorKind.unknown,
        errorMessage: 'Error inesperado: $e',
      ));
    }
  }

  Future<void> _writeCache(String townId, TownGuideState s) async {
    try {
      await _prefs.setString(
          '${AppConstants.prefsGuideCachePrefix}$townId', s.encodeForCache());
    } catch (_) {
      // La caché es una optimización; un fallo aquí no debe romper la UI.
    }
  }

  // ═══════════════════════════════════════════════════════════════════════
  //  GENERACIÓN DE LA FICHA CON LLM
  // ═══════════════════════════════════════════════════════════════════════

  Future<AiTownGuide> _generateGuide(
      TownModel town, AppSettings settings, String? tripContext) async {
    if (!settings.hasLlmKey) {
      throw const AiExplorerException(AiErrorKind.noApiKey,
          'Configura tu API Key de IA en Ajustes para ver la ficha del pueblo.');
    }

    final user = _buildUserPrompt(town, tripContext);

    // Plan de intentos:
    //  · Gemini + grounding: 1º con Google Search (investiga en internet), 2º sin
    //    búsqueda y con esquema JSON estricto (respaldo si la búsqueda falla).
    //  · Resto: dos intentos normales (reintento si el JSON viene roto).
    final wantsGrounding =
        settings.provider == LlmProvider.gemini && settings.useWebGrounding;
    final plans = wantsGrounding ? const [true, false] : const [false, false];
    AiExplorerException? lastError;

    for (final grounded in plans) {
      try {
        final out = await _callLlm(
          settings,
          system: grounded ? '$_systemPrompt\n\n$_groundingAddendum' : _systemPrompt,
          user: user,
          schema: _geminiSchema,
          maxTokens: 4096,
          grounding: grounded,
        );
        return AiTownGuide.fromLlmJson(
          _extractJson(out.text),
          fallbackName: town.nombreLugar,
          provider: settings.provider.label,
          model: out.model ?? settings.effectiveModel,
          fuentes: out.sources,
          grounded: out.grounded,
        );
      } on FormatException catch (e) {
        lastError = AiExplorerException(AiErrorKind.invalidResponse,
            'La IA devolvió una respuesta que no se pudo leer (${e.message}).');
      } on AiExplorerException catch (e) {
        const recoverable = {
          AiErrorKind.invalidResponse,
          AiErrorKind.unknown,
          AiErrorKind.quota,
        };
        // Errores de clave o de red no se arreglan quitando la búsqueda web.
        if (!grounded || !recoverable.contains(e.kind)) rethrow;
        lastError = e;
      }
    }
    throw lastError!;
  }

  static const String _systemPrompt = '''
Eres "RutaViva", guía local experto en turismo, gastronomía e historia de las carreteras del Perú (Panamericana Sur y rutas costeras y andinas). Respondes SIEMPRE en español peruano neutro, con tono cercano, conciso y útil para un viajero en bus con poco tiempo.

REGLAS ESTRICTAS:
1. Devuelve EXCLUSIVAMENTE un objeto JSON válido que cumpla el esquema. Sin markdown, sin bloques de código, sin texto antes o después.
2. No inventes. Si no estás seguro de un negocio, dato o fecha, usa referencias genéricas ("restaurantes alrededor de la plaza", "paraderos junto a la carretera"). No des teléfonos, precios exactos ni horarios.
3. Prioriza lo que está sobre la carretera o a máximo 15 minutos del punto.
4. "resumen_historico_curioso": máximo 3 líneas (unas 45 palabras), atrapantes, sobre historia, geografía o fama del lugar.
5. "gastronomia_imperdible": entre 2 y 4 platos o productos típicos REALES de la zona. "donde_buscarlo" indica el tipo de lugar (plaza, mercado, paraderos de carretera), no inventes nombres propios dudosos.
6. "lugares_y_paradas": entre 2 y 5 lugares. "tipo" debe ser exactamente uno de: Mirador, Playa, Plaza, Ruinas, Paradero Gastronómico.
7. Si la localidad es un CRUCE o DESVÍO, describe el pueblo o atractivo al que se accede desde ahí y la distancia aproximada.
8. "recomendacion_viajero": un consejo práctico (señal móvil, cajeros, seguridad, mejor hora para parar). Si no tienes certeza sobre cajeros o señal, da una recomendación prudente y general.

ESQUEMA JSON:
{
  "nombre_pueblo": "string",
  "resumen_historico_curioso": "string",
  "clima_y_geografia": "string (altitud, sensación térmica típica y paisaje)",
  "gastronomia_imperdible": [
    { "plato": "string", "descripcion": "string", "donde_buscarlo": "string" }
  ],
  "lugares_y_paradas": [
    { "nombre": "string", "tipo": "Mirador | Playa | Plaza | Ruinas | Paradero Gastronómico",
      "distancia_carretera": "string", "detalle": "string" }
  ],
  "recomendacion_viajero": "string"
}''';

  String _buildUserPrompt(TownModel town, String? tripContext) {
    final b = StringBuffer()
      ..writeln('Localidad: ${town.nombre}')
      ..writeln('Provincia / Departamento: ${town.provincia} / ${town.departamento}')
      ..writeln('Altitud: ${town.msnm} msnm')
      ..writeln('Coordenadas: ${town.lat}, ${town.lng}')
      ..writeln('Kilómetro aproximado de la Panamericana Sur desde Lima: ${town.kmRuta.round()}')
      ..writeln('Tipo de punto: ${town.tipo.label}')
      ..writeln('Nota del mapa: ${town.etiqueta}');
    if (town.tipo == TownType.desvio) {
      b.writeln('Está a unos ${town.desvioKm.round()} km de la carretera principal.');
    }
    if (tripContext != null && tripContext.trim().isNotEmpty) {
      b.writeln('Contexto del viaje: ${tripContext.trim()}');
    }
    b.write('Genera la ficha JSON de este lugar para un viajero que pasa en bus.');
    return b.toString();
  }

  /// Esquema para `responseSchema` de Gemini (tipos en mayúsculas).
  static const Map<String, dynamic> _geminiSchema = {
    'type': 'OBJECT',
    'properties': {
      'nombre_pueblo': {'type': 'STRING'},
      'resumen_historico_curioso': {'type': 'STRING'},
      'clima_y_geografia': {'type': 'STRING'},
      'gastronomia_imperdible': {
        'type': 'ARRAY',
        'items': {
          'type': 'OBJECT',
          'properties': {
            'plato': {'type': 'STRING'},
            'descripcion': {'type': 'STRING'},
            'donde_buscarlo': {'type': 'STRING'},
          },
          'required': ['plato', 'descripcion', 'donde_buscarlo'],
        },
      },
      'lugares_y_paradas': {
        'type': 'ARRAY',
        'items': {
          'type': 'OBJECT',
          'properties': {
            'nombre': {'type': 'STRING'},
            'tipo': {
              'type': 'STRING',
              'enum': [
                'Mirador',
                'Playa',
                'Plaza',
                'Ruinas',
                'Paradero Gastronómico'
              ],
            },
            'distancia_carretera': {'type': 'STRING'},
            'detalle': {'type': 'STRING'},
          },
          'required': ['nombre', 'tipo', 'distancia_carretera', 'detalle'],
        },
      },
      'recomendacion_viajero': {'type': 'STRING'},
    },
    'required': [
      'nombre_pueblo',
      'resumen_historico_curioso',
      'clima_y_geografia',
      'gastronomia_imperdible',
      'lugares_y_paradas',
      'recomendacion_viajero',
    ],
  };

  // ═══════════════════════════════════════════════════════════════════════
  //  CLIENTES REST (Gemini / OpenAI-compatible / Anthropic)
  // ═══════════════════════════════════════════════════════════════════════

  /// Se añade al prompt de sistema cuando está activo el grounding de búsqueda.
  static const String _groundingAddendum = '''
MODO BÚSQUEDA WEB ACTIVADO (tiene prioridad sobre las reglas 2 y 5 en lo referente a nombres propios):
- Usa Google Search para investigar HOY restaurantes, paraderos, platos típicos y atractivos reales de la localidad indicada.
- Puedes nombrar negocios y lugares concretos SOLO si aparecen en resultados confiables y no hay indicios de que hayan cerrado. Si dudas, usa referencias genéricas.
- No incluyas teléfonos, precios ni horarios exactos.
- Tu respuesta final debe ser ÚNICAMENTE el objeto JSON del esquema: sin texto previo, sin markdown, sin marcas de cita ni notas.''';

  Future<_LlmOutput> _callLlm(
    AppSettings s, {
    required String system,
    required String user,
    required Map<String, dynamic>? schema,
    required int maxTokens,
    required bool grounding,
  }) async {
    switch (s.provider) {
      case LlmProvider.gemini:
        return _callGemini(s, system, user, schema, maxTokens,
            grounding: grounding);
      case LlmProvider.openai:
        return _LlmOutput(text: await _callOpenAi(s, system, user));
      case LlmProvider.anthropic:
        return _LlmOutput(text: await _callAnthropic(s, system, user, maxTokens));
    }
  }

  String? _preferredModel;
  String? _preferredFor;

  /// Pre-carga en segundo plano: descarga fotos + ficha IA y las deja en la
  /// caché local para que la hoja del pueblo abra al instante.
  /// Devuelve `true` si ya había caché o si se generó una ficha.
  Future<bool> prefetch(TownModel town,
      {required AppSettings settings, String? tripContext}) async {
    try {
      if (!settings.hasLlmKey) return false;
      if (await readCache(town.id) != null) return true;
      await for (final _ in loadTownGuide(town,
          settings: settings, tripContext: tripContext)) {}
      return await readCache(town.id) != null;
    } catch (_) {
      return false;
    }
  }

  /// Llama a Gemini con cascada automática:
  ///  · Modelos: el configurado y luego gemini-3.8-flash, gemini-3.0-flash,
  ///    gemini-3-flash-preview, gemini-2.5-pro, gemini-2.0-flash (si hay HTTP 404 se pasa al siguiente).
  ///  · Variantes por modelo (si hay HTTP 400): con google_search → sin tools con
  ///    esquema JSON → solo prompt. Así la guía SIEMPRE intenta generarse.
  Future<_LlmOutput> _callGemini(AppSettings s, String system, String user,
      Map<String, dynamic>? schema, int maxTokens,
      {required bool grounding}) async {
    final models = <String>[];
    // El último modelo que respondió bien va primero: evita un 404 previo en
    // cada llamada (latencia).
    final preferred =
        (_preferredFor == s.effectiveModel) ? _preferredModel : null;
    for (final m in [
      if (preferred != null) preferred,
      s.effectiveModel,
      ...AppConstants.geminiFallbackModels,
    ]) {
      if (m.isNotEmpty && !models.contains(m)) models.add(m);
    }
    // (usa google_search, usa responseSchema)
    final variants = grounding
        ? const <(bool, bool)>[(true, false), (false, true), (false, false)]
        : const <(bool, bool)>[(false, true), (false, false)];

    AiExplorerException? last;
    for (final model in models) {
      for (final v in variants) {
        try {
          final out = await _callGeminiOnce(
              s, model, system, user, schema, maxTokens,
              tools: v.$1, useSchema: v.$2);
          _preferredModel = model;
          _preferredFor = s.effectiveModel;
          return out;
        } on AiExplorerException catch (e) {
          last = e;
          if (e.statusCode == 404) break; // modelo no disponible → siguiente
          if (e.statusCode == 400 && e.kind != AiErrorKind.auth) continue;
          rethrow; // clave, red, cuota, servidor…
        }
      }
    }
    throw last ??
        const AiExplorerException(
            AiErrorKind.unknown, 'No hay modelos de Gemini disponibles.');
  }

  Future<_LlmOutput> _callGeminiOnce(AppSettings s, String model, String system,
      String user, Map<String, dynamic>? schema, int maxTokens,
      {required bool tools, required bool useSchema}) async {
    final uri = Uri.https('generativelanguage.googleapis.com',
        '/v1beta/models/$model:generateContent');

    final generationConfig = <String, dynamic>{
      'temperature': tools ? 0.3 : 0.4,
      'maxOutputTokens': maxTokens,
      // Con google_search no se admite responseMimeType/responseSchema.
      if (!tools && useSchema) 'responseMimeType': 'application/json',
      if (!tools && useSchema && schema != null) 'responseSchema': schema,
      if (model.contains('2.5') && model.contains('flash'))
        'thinkingConfig': {'thinkingBudget': 0},
    };

    final json = await _postJson(
      uri,
      {'Content-Type': 'application/json', 'x-goog-api-key': s.llmApiKey.trim()},
      {
        'systemInstruction': {
          'parts': [
            {'text': system}
          ]
        },
        'contents': [
          {
            'role': 'user',
            'parts': [
              {'text': user}
            ]
          }
        ],
        'generationConfig': generationConfig,
        if (tools)
          'tools': [
            {'google_search': {}}
          ],
      },
    );

    final feedback = json['promptFeedback'];
    if (feedback is Map && feedback['blockReason'] != null) {
      throw const AiExplorerException(AiErrorKind.blocked,
          'La IA bloqueó la consulta por sus filtros de seguridad.');
    }
    final candidates = json['candidates'];
    if (candidates is! List || candidates.isEmpty || candidates.first is! Map) {
      throw const AiExplorerException(
          AiErrorKind.invalidResponse, 'Gemini no devolvió resultados.');
    }
    final cand = Map<String, dynamic>.from(candidates.first as Map);
    final parts = (cand['content'] as Map?)?['parts'];
    final text = parts is List
        ? parts
            .whereType<Map>()
            .where((p) => p['thought'] != true)
            .map((p) => (p['text'] ?? '').toString())
            .join()
        : '';
    if (text.trim().isEmpty) {
      final reason = cand['finishReason'];
      throw AiExplorerException(
        reason == 'SAFETY' ? AiErrorKind.blocked : AiErrorKind.invalidResponse,
        reason == 'SAFETY'
            ? 'La IA bloqueó la respuesta por sus filtros de seguridad.'
            : 'Gemini devolvió una respuesta vacía.',
      );
    }
    return _LlmOutput(
      text: text,
      sources: tools ? _groundingSources(cand) : const [],
      grounded: tools,
      model: model,
    );
  }

  /// Páginas web que Gemini usó para fundamentar la respuesta.
  List<GuideSource> _groundingSources(Map<String, dynamic> candidate) {
    final meta = candidate['groundingMetadata'];
    final chunks = meta is Map ? meta['groundingChunks'] : null;
    if (chunks is! List) return const [];
    final seen = <String>{};
    final out = <GuideSource>[];
    for (final c in chunks) {
      final web = c is Map ? c['web'] : null;
      if (web is! Map) continue;
      final uri = (web['uri'] ?? '').toString();
      if (uri.isEmpty || !seen.add(uri)) continue;
      final title = (web['title'] ?? '').toString();
      out.add(GuideSource(titulo: title.isEmpty ? uri : title, url: uri));
      if (out.length >= 6) break;
    }
    return out;
  }

  Future<String> _callOpenAi(AppSettings s, String system, String user) async {
    var base = s.openAiBaseUrl.trim();
    if (base.isEmpty) base = 'https://api.openai.com/v1';
    if (base.endsWith('/')) base = base.substring(0, base.length - 1);

    final json = await _postJson(
      Uri.parse('$base/chat/completions'),
      {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer ${s.llmApiKey.trim()}',
      },
      {
        'model': s.effectiveModel,
        'messages': [
          {'role': 'system', 'content': system},
          {'role': 'user', 'content': user},
        ],
        'response_format': {'type': 'json_object'},
      },
    );
    final choices = json['choices'];
    if (choices is List && choices.isNotEmpty && choices.first is Map) {
      final content = ((choices.first as Map)['message'] as Map?)?['content'];
      if (content is String && content.trim().isNotEmpty) return content;
    }
    throw const AiExplorerException(
        AiErrorKind.invalidResponse, 'El proveedor no devolvió contenido.');
  }

  Future<String> _callAnthropic(
      AppSettings s, String system, String user, int maxTokens) async {
    final json = await _postJson(
      Uri.https('api.anthropic.com', '/v1/messages'),
      {
        'Content-Type': 'application/json',
        'x-api-key': s.llmApiKey.trim(),
        'anthropic-version': '2023-06-01',
      },
      {
        'model': s.effectiveModel,
        'max_tokens': maxTokens,
        'system': system,
        'messages': [
          {'role': 'user', 'content': user},
        ],
      },
    );
    final content = json['content'];
    final text = content is List
        ? content
            .whereType<Map>()
            .where((b) => b['type'] == 'text')
            .map((b) => (b['text'] ?? '').toString())
            .join()
        : '';
    if (text.trim().isEmpty) {
      throw const AiExplorerException(
          AiErrorKind.invalidResponse, 'Claude devolvió una respuesta vacía.');
    }
    return text;
  }

  // ═══════════════════════════════════════════════════════════════════════
  //  HTTP + PARSEO
  // ═══════════════════════════════════════════════════════════════════════

  Future<Map<String, dynamic>> _postJson(
    Uri uri,
    Map<String, String> headers,
    Map<String, dynamic> body,
  ) async {
    const maxAttempts = 2;
    for (var attempt = 1;; attempt++) {
      try {
        final res = await _client
            .post(uri, headers: headers, body: jsonEncode(body))
            .timeout(AppConstants.llmTimeout);

        if (res.statusCode >= 200 && res.statusCode < 300) {
          final decoded = jsonDecode(utf8.decode(res.bodyBytes));
          if (decoded is Map<String, dynamic>) return decoded;
          throw const AiExplorerException(
              AiErrorKind.invalidResponse, 'Respuesta inesperada de la IA.');
        }
        final retryable = res.statusCode == 429 || res.statusCode >= 500;
        if (retryable && attempt < maxAttempts) {
          await Future<void>.delayed(const Duration(seconds: 2));
          continue;
        }
        throw _httpError(res);
      } on TimeoutException {
        if (attempt < maxAttempts) continue;
        throw const AiExplorerException(AiErrorKind.network,
            'La IA tardó demasiado en responder. Revisa tu señal e inténtalo de nuevo.');
      } on SocketException {
        throw const AiExplorerException(
            AiErrorKind.network, 'Sin conexión a internet.');
      } on http.ClientException {
        throw const AiExplorerException(
            AiErrorKind.network, 'Sin conexión a internet.');
      } on FormatException {
        throw const AiExplorerException(
            AiErrorKind.invalidResponse, 'La IA respondió con un formato ilegible.');
      }
    }
  }

  AiExplorerException _httpError(http.Response r) {
    final base = _httpErrorBase(r);
    return AiExplorerException(base.kind, base.message, statusCode: r.statusCode);
  }

  AiExplorerException _httpErrorBase(http.Response r) {
    var detail = '';
    try {
      final j = jsonDecode(utf8.decode(r.bodyBytes));
      if (j is Map) {
        final e = j['error'];
        if (e is Map) {
          detail = (e['message'] ?? '').toString();
        } else if (e is String) {
          detail = e;
        }
      }
    } catch (_) {}

    final code = r.statusCode;
    final lower = detail.toLowerCase();
    final suffix = detail.isEmpty ? '' : ' ($detail)';

    if (code == 401 ||
        code == 403 ||
        (code == 400 && (lower.contains('api key') || lower.contains('api_key')))) {
      return AiExplorerException(
          AiErrorKind.auth, 'API Key inválida o sin permisos$suffix');
    }
    if (code == 429) {
      return AiExplorerException(
          AiErrorKind.quota, 'Límite de uso de la IA alcanzado$suffix');
    }
    if (code >= 500) {
      return AiExplorerException(
          AiErrorKind.server, 'El servicio de IA no está disponible ($code).');
    }
    return AiExplorerException(AiErrorKind.unknown, 'Error de IA ($code)$suffix');
  }

  /// Extrae el objeto JSON aunque el modelo lo envuelva en ```json … ```.
  Map<String, dynamic> _extractJson(String text) {
    var t = text.trim();
    t = t.replaceAll(RegExp(r'^```(?:json)?\s*', caseSensitive: false), '');
    t = t.replaceAll(RegExp(r'\s*```$'), '');
    final start = t.indexOf('{');
    final end = t.lastIndexOf('}');
    if (start < 0 || end <= start) {
      throw const FormatException('no se encontró un objeto JSON');
    }
    final decoded = jsonDecode(t.substring(start, end + 1));
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('el JSON no es un objeto');
    }
    return decoded;
  }
}

/// Respuesta del LLM + fuentes web (si hubo grounding).
class _LlmOutput {
  const _LlmOutput({
    required this.text,
    this.sources = const [],
    this.grounded = false,
    this.model,
  });
  final String text;
  final List<GuideSource> sources;
  final bool grounded;
  final String? model;
}
