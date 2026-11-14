import 'package:flutter/material.dart' show IconData, Icons;
import 'dart:convert';

/// Tipos de error del módulo de exploración IA.
enum AiErrorKind {
  noApiKey,
  network,
  auth,
  quota,
  server,
  blocked,
  invalidResponse,
  unknown,
}

String _str(dynamic v, [String fallback = '']) {
  if (v == null) return fallback;
  final s = v is String ? v : v.toString();
  final t = s.trim();
  return t.isEmpty ? fallback : t;
}

List<Map<String, dynamic>> _maps(dynamic v) => v is List
    ? v.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList()
    : const <Map<String, dynamic>>[];

// ─────────────────────────────────────────────────────────────────────────
// Fotos
// ─────────────────────────────────────────────────────────────────────────

/// Foto real (Wikipedia / Wikimedia Commons) con datos de atribución.
class TownPhoto {
  const TownPhoto({
    required this.url,
    required this.title,
    required this.source,
    this.thumbUrl,
    this.author,
    this.license,
    this.pageUrl,
    this.width,
    this.height,
  });

  final String url;
  final String? thumbUrl;
  final String title;
  final String? author;
  final String? license;
  final String source;
  final String? pageUrl;
  final int? width;
  final int? height;

  /// Texto de crédito para mostrar bajo la foto.
  String get attribution {
    final parts = <String>[
      if (author != null && author!.isNotEmpty) author!,
      if (license != null && license!.isNotEmpty) license!,
      source,
    ];
    return parts.join(' · ');
  }

  Map<String, dynamic> toJson() => {
        'url': url,
        'thumbUrl': thumbUrl,
        'title': title,
        'author': author,
        'license': license,
        'source': source,
        'pageUrl': pageUrl,
        'width': width,
        'height': height,
      };

  factory TownPhoto.fromJson(Map<String, dynamic> j) => TownPhoto(
        url: _str(j['url']),
        thumbUrl: j['thumbUrl'] as String?,
        title: _str(j['title']),
        author: j['author'] as String?,
        license: j['license'] as String?,
        source: _str(j['source'], 'Wikimedia'),
        pageUrl: j['pageUrl'] as String?,
        width: (j['width'] as num?)?.toInt(),
        height: (j['height'] as num?)?.toInt(),
      );
}

// ─────────────────────────────────────────────────────────────────────────
// Contenido generado por la IA
// ─────────────────────────────────────────────────────────────────────────

class GastronomyItem {
  const GastronomyItem({
    required this.plato,
    required this.descripcion,
    required this.dondeBuscarlo,
    this.foto,
  });

  final String plato;
  final String descripcion;
  final String dondeBuscarlo;
  final TownPhoto? foto;

  GastronomyItem copyWith({TownPhoto? foto}) => GastronomyItem(
        plato: plato,
        descripcion: descripcion,
        dondeBuscarlo: dondeBuscarlo,
        foto: foto ?? this.foto,
      );

  Map<String, dynamic> toJson() => {
        'plato': plato,
        'descripcion': descripcion,
        'donde_buscarlo': dondeBuscarlo,
        'foto': foto?.toJson(),
      };

  factory GastronomyItem.fromJson(Map<String, dynamic> j) => GastronomyItem(
        plato: _str(j['plato']),
        descripcion: _str(j['descripcion']),
        dondeBuscarlo: _str(j['donde_buscarlo']),
        foto: j['foto'] is Map
            ? TownPhoto.fromJson(Map<String, dynamic>.from(j['foto'] as Map))
            : null,
      );
}

enum StopKind {
  mirador('Mirador', Icons.landscape_outlined),
  playa('Playa', Icons.beach_access_outlined),
  plaza('Plaza', Icons.location_city_outlined),
  ruinas('Ruinas', Icons.account_balance_outlined),
  paraderoGastronomico('Paradero Gastronómico', Icons.restaurant_outlined),
  otro('Lugar', Icons.place_outlined);

  const StopKind(this.label, this.icon);
  final String label;
  final IconData icon;

  static StopKind parse(String raw) {
    final s = raw.toLowerCase();
    if (s.contains('mirador')) return StopKind.mirador;
    if (s.contains('playa')) return StopKind.playa;
    if (s.contains('plaza')) return StopKind.plaza;
    if (s.contains('ruina') || s.contains('arqueol')) return StopKind.ruinas;
    if (s.contains('paradero') || s.contains('gastro') || s.contains('restaur')) {
      return StopKind.paraderoGastronomico;
    }
    return StopKind.otro;
  }
}

class StopItem {
  const StopItem({
    required this.nombre,
    required this.tipo,
    required this.distanciaCarretera,
    required this.detalle,
  });

  final String nombre;
  final String tipo;
  final String distanciaCarretera;
  final String detalle;

  StopKind get kind => StopKind.parse(tipo);

  Map<String, dynamic> toJson() => {
        'nombre': nombre,
        'tipo': tipo,
        'distancia_carretera': distanciaCarretera,
        'detalle': detalle,
      };

  factory StopItem.fromJson(Map<String, dynamic> j) => StopItem(
        nombre: _str(j['nombre']),
        tipo: _str(j['tipo'], 'Lugar'),
        distanciaCarretera: _str(j['distancia_carretera']),
        detalle: _str(j['detalle']),
      );
}

/// Fuente web consultada por el grounding de búsqueda de Gemini.
class GuideSource {
  const GuideSource({required this.titulo, required this.url});
  final String titulo;
  final String url;

  Map<String, dynamic> toJson() => {'titulo': titulo, 'url': url};

  factory GuideSource.fromJson(Map<String, dynamic> j) =>
      GuideSource(titulo: _str(j['titulo']), url: _str(j['url']));
}

/// Ficha turística generada por el LLM (esquema JSON estricto).
class AiTownGuide {
  const AiTownGuide({
    required this.nombrePueblo,
    required this.resumenHistoricoCurioso,
    required this.climaYGeografia,
    required this.gastronomia,
    required this.lugares,
    required this.recomendacionViajero,
    required this.generatedAt,
    required this.provider,
    required this.model,
    this.fuentes = const [],
    this.groundedWithSearch = false,
  });

  final String nombrePueblo;
  final String resumenHistoricoCurioso;
  final String climaYGeografia;
  final List<GastronomyItem> gastronomia;
  final List<StopItem> lugares;
  final String recomendacionViajero;
  final DateTime generatedAt;
  final String provider;
  final String model;

  /// Páginas web usadas por Google Search (vacío si no hubo grounding).
  final List<GuideSource> fuentes;
  final bool groundedWithSearch;

  AiTownGuide copyWith({List<GastronomyItem>? gastronomia}) => AiTownGuide(
        nombrePueblo: nombrePueblo,
        resumenHistoricoCurioso: resumenHistoricoCurioso,
        climaYGeografia: climaYGeografia,
        gastronomia: gastronomia ?? this.gastronomia,
        lugares: lugares,
        recomendacionViajero: recomendacionViajero,
        generatedAt: generatedAt,
        provider: provider,
        model: model,
        fuentes: fuentes,
        groundedWithSearch: groundedWithSearch,
      );

  /// Parseo tolerante: la IA puede omitir campos o devolver tipos distintos.
  factory AiTownGuide.fromLlmJson(
    Map<String, dynamic> j, {
    required String fallbackName,
    required String provider,
    required String model,
    List<GuideSource> fuentes = const [],
    bool grounded = false,
  }) {
    final gastro = _maps(j['gastronomia_imperdible'])
        .map(GastronomyItem.fromJson)
        .where((g) => g.plato.isNotEmpty)
        .toList();
    final places = _maps(j['lugares_y_paradas'])
        .map(StopItem.fromJson)
        .where((p) => p.nombre.isNotEmpty)
        .toList();
    final resumen = _str(j['resumen_historico_curioso']);
    if (resumen.isEmpty && gastro.isEmpty && places.isEmpty) {
      throw const FormatException('La IA devolvió una ficha vacía.');
    }
    return AiTownGuide(
      nombrePueblo: _str(j['nombre_pueblo'], fallbackName),
      resumenHistoricoCurioso: resumen,
      climaYGeografia: _str(j['clima_y_geografia']),
      gastronomia: gastro,
      lugares: places,
      recomendacionViajero: _str(j['recomendacion_viajero']),
      generatedAt: DateTime.now(),
      provider: provider,
      model: model,
      fuentes: fuentes,
      groundedWithSearch: grounded,
    );
  }

  Map<String, dynamic> toJson() => {
        'nombre_pueblo': nombrePueblo,
        'resumen_historico_curioso': resumenHistoricoCurioso,
        'clima_y_geografia': climaYGeografia,
        'gastronomia_imperdible': gastronomia.map((e) => e.toJson()).toList(),
        'lugares_y_paradas': lugares.map((e) => e.toJson()).toList(),
        'recomendacion_viajero': recomendacionViajero,
        'generatedAt': generatedAt.toIso8601String(),
        'provider': provider,
        'model': model,
        'fuentes': fuentes.map((e) => e.toJson()).toList(),
        'grounded': groundedWithSearch,
      };

  factory AiTownGuide.fromCacheJson(Map<String, dynamic> j) => AiTownGuide(
        nombrePueblo: _str(j['nombre_pueblo']),
        resumenHistoricoCurioso: _str(j['resumen_historico_curioso']),
        climaYGeografia: _str(j['clima_y_geografia']),
        gastronomia:
            _maps(j['gastronomia_imperdible']).map(GastronomyItem.fromJson).toList(),
        lugares: _maps(j['lugares_y_paradas']).map(StopItem.fromJson).toList(),
        recomendacionViajero: _str(j['recomendacion_viajero']),
        generatedAt:
            DateTime.tryParse(_str(j['generatedAt'])) ?? DateTime.now(),
        provider: _str(j['provider']),
        model: _str(j['model']),
        fuentes: _maps(j['fuentes'])
            .map(GuideSource.fromJson)
            .where((f) => f.url.isNotEmpty)
            .toList(),
        groundedWithSearch: j['grounded'] == true,
      );
}

// ─────────────────────────────────────────────────────────────────────────
// Restaurantes reales (Google Places API New, opcional)
// ─────────────────────────────────────────────────────────────────────────

class RoadsidePlace {
  const RoadsidePlace({
    required this.id,
    required this.nombre,
    this.direccion,
    this.rating,
    this.ratingCount,
    this.abiertoAhora,
    this.photoUrl,
    this.lat,
    this.lng,
    this.tipo,
    this.mapsUrl,
    this.distanciaKm,
  });

  final String id;
  final String nombre;
  final String? direccion;
  final double? rating;
  final int? ratingCount;
  final bool? abiertoAhora;
  final String? photoUrl;
  final double? lat;
  final double? lng;
  final String? tipo;
  final String? mapsUrl;
  final double? distanciaKm;

  Map<String, dynamic> toJson() => {
        'id': id,
        'nombre': nombre,
        'direccion': direccion,
        'rating': rating,
        'ratingCount': ratingCount,
        'abiertoAhora': abiertoAhora,
        'photoUrl': photoUrl,
        'lat': lat,
        'lng': lng,
        'tipo': tipo,
        'mapsUrl': mapsUrl,
        'distanciaKm': distanciaKm,
      };

  factory RoadsidePlace.fromJson(Map<String, dynamic> j) => RoadsidePlace(
        id: _str(j['id']),
        nombre: _str(j['nombre']),
        direccion: j['direccion'] as String?,
        rating: (j['rating'] as num?)?.toDouble(),
        ratingCount: (j['ratingCount'] as num?)?.toInt(),
        abiertoAhora: j['abiertoAhora'] as bool?,
        photoUrl: j['photoUrl'] as String?,
        lat: (j['lat'] as num?)?.toDouble(),
        lng: (j['lng'] as num?)?.toDouble(),
        tipo: j['tipo'] as String?,
        mapsUrl: j['mapsUrl'] as String?,
        distanciaKm: (j['distanciaKm'] as num?)?.toDouble(),
      );
}

// ─────────────────────────────────────────────────────────────────────────
// Estado progresivo que consume la UI (texto IA, fotos y lugares llegan
// en momentos distintos).
// ─────────────────────────────────────────────────────────────────────────

class TownGuideState {
  const TownGuideState({
    required this.townId,
    this.guide,
    this.photos = const [],
    this.places = const [],
    this.loadingGuide = false,
    this.loadingPhotos = false,
    this.loadingPlaces = false,
    this.fromCache = false,
    this.errorKind,
    this.errorMessage,
    this.placesError,
    this.cachedAt,
  });

  factory TownGuideState.initial(String townId) =>
      TownGuideState(townId: townId);

  final String townId;
  final AiTownGuide? guide;
  final List<TownPhoto> photos;
  final List<RoadsidePlace> places;
  final bool loadingGuide;
  final bool loadingPhotos;
  final bool loadingPlaces;
  final bool fromCache;
  final AiErrorKind? errorKind;
  final String? errorMessage;
  final String? placesError;
  final DateTime? cachedAt;

  bool get hasGuide => guide != null;
  bool get isBusy => loadingGuide || loadingPhotos || loadingPlaces;
  bool get hasError => errorKind != null;

  TownGuideState copyWith({
    AiTownGuide? guide,
    List<TownPhoto>? photos,
    List<RoadsidePlace>? places,
    bool? loadingGuide,
    bool? loadingPhotos,
    bool? loadingPlaces,
    bool? fromCache,
    AiErrorKind? errorKind,
    String? errorMessage,
    String? placesError,
    DateTime? cachedAt,
    bool clearError = false,
    bool clearPlacesError = false,
  }) =>
      TownGuideState(
        townId: townId,
        guide: guide ?? this.guide,
        photos: photos ?? this.photos,
        places: places ?? this.places,
        loadingGuide: loadingGuide ?? this.loadingGuide,
        loadingPhotos: loadingPhotos ?? this.loadingPhotos,
        loadingPlaces: loadingPlaces ?? this.loadingPlaces,
        fromCache: fromCache ?? this.fromCache,
        errorKind: clearError ? null : (errorKind ?? this.errorKind),
        errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
        placesError:
            clearPlacesError ? null : (placesError ?? this.placesError),
        cachedAt: cachedAt ?? this.cachedAt,
      );

  /// Serialización para la caché local (solo si hay ficha).
  String encodeForCache() => jsonEncode({
        'townId': townId,
        'cachedAt': DateTime.now().toIso8601String(),
        'guide': guide?.toJson(),
        'photos': photos.map((e) => e.toJson()).toList(),
        'places': places.map((e) => e.toJson()).toList(),
      });

  static TownGuideState? decodeFromCache(String raw) {
    try {
      final j = jsonDecode(raw) as Map<String, dynamic>;
      if (j['guide'] is! Map) return null;
      return TownGuideState(
        townId: _str(j['townId']),
        guide: AiTownGuide.fromCacheJson(
            Map<String, dynamic>.from(j['guide'] as Map)),
        photos: _maps(j['photos']).map(TownPhoto.fromJson).toList(),
        places: _maps(j['places']).map(RoadsidePlace.fromJson).toList(),
        fromCache: true,
        cachedAt: DateTime.tryParse(_str(j['cachedAt'])),
      );
    } catch (_) {
      return null;
    }
  }
}
