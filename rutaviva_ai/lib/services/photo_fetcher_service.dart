import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../core/app_constants.dart';
import '../models/ai_town_guide.dart';
import '../models/town_model.dart';
import 'offline_geocoder_service.dart';

/// Error de Google Places (clave inválida, API no habilitada, cuota…).
class PlacesApiException implements Exception {
  const PlacesApiException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Obtiene fotos reales sin API key (Wikipedia/Wikimedia) y, opcionalmente,
/// restaurantes con fotos y calificación vía Google Places API (New).
///
/// Los métodos de Wikimedia NUNCA lanzan excepciones: si falla la red devuelven
/// listas vacías para que la UI muestre el resto del contenido.
class PhotoFetcherService {
  PhotoFetcherService({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  static const Map<String, String> _wikiHeaders = {
    'User-Agent': AppConstants.httpUserAgent,
    'Api-User-Agent': AppConstants.httpUserAgent,
    'Accept': 'application/json',
  };

  /// Títulos que casi nunca son fotos del lugar (mapas, escudos, banderas…).
  static final RegExp _junkTitle = RegExp(
    r'(mapa|map\b|escudo|logo|bandera|flag|coat[_ ]of|locator|diagram|esquema|'
    r'plano|ubicaci[oó]n|cartel|poster|afiche|\bsign\b|screenshot|captura)',
    caseSensitive: false,
  );

  // ═══════════════════════════════════════════════════════════════════════
  //  FOTOS DEL PUEBLO
  // ═══════════════════════════════════════════════════════════════════════

  /// Combina tres fuentes en paralelo y devuelve hasta [maxPhotos] fotos únicas:
  ///  1. Imagen principal del artículo (REST summary de es.wikipedia).
  ///  2. Archivos de Commons georreferenciados (generator=geosearch, ggscoord).
  ///  3. Imágenes de artículos cercanos de es.wikipedia.
  Future<List<TownPhoto>> fetchTownPhotos(TownModel town,
      {int maxPhotos = 8}) async {
    final results = await Future.wait<List<TownPhoto>>([
      _safe(() => _wikipediaSummaryPhotos(town)),
      _safe(() => _commonsGeoPhotos(town)),
      _safe(() => _wikipediaGeoPagePhotos(town)),
    ]);

    final seen = <String>{};
    final merged = <TownPhoto>[];
    for (final list in results) {
      for (final p in list) {
        if (p.url.isEmpty || !seen.add(p.url)) continue;
        merged.add(p);
        if (merged.length >= maxPhotos) return merged;
      }
    }
    return merged;
  }

  Future<List<TownPhoto>> _wikipediaSummaryPhotos(TownModel town) async {
    final title = (town.wikipedia ?? town.nombreLugar).replaceAll(' ', '_');
    final uri = Uri.https('es.wikipedia.org', '/api/rest_v1/page/summary/$title');
    final json = await _getJson(uri);
    if (json == null || json['type'] == 'disambiguation') return const [];

    final original = json['originalimage'];
    final thumb = json['thumbnail'];
    String? url;
    int? w;
    int? h;
    // Los originales pueden pesar decenas de MB: se prefiere la miniatura grande.
    if (original is Map && ((original['width'] as num?) ?? 99999) <= 2000) {
      url = original['source'] as String?;
      w = (original['width'] as num?)?.toInt();
      h = (original['height'] as num?)?.toInt();
    } else if (thumb is Map) {
      url = thumb['source'] as String?;
      w = (thumb['width'] as num?)?.toInt();
      h = (thumb['height'] as num?)?.toInt();
    }
    if (url == null || url.toLowerCase().endsWith('.svg')) return const [];

    String? pageUrl;
    if (json['content_urls'] is Map && (json['content_urls'] as Map)['desktop'] is Map) {
      pageUrl = ((json['content_urls'] as Map)['desktop'] as Map)['page']?.toString();
    }

    return [
      TownPhoto(
        url: url,
        thumbUrl: thumb is Map ? thumb['source'] as String? : null,
        title: (json['title'] as String?) ?? town.nombreLugar,
        license: 'Wikipedia',
        source: 'Wikimedia Commons',
        pageUrl: pageUrl,
        width: w,
        height: h,
      ),
    ];
  }

  Future<List<TownPhoto>> _commonsGeoPhotos(TownModel town) async {
    final uri = Uri.https('commons.wikimedia.org', '/w/api.php', {
      'action': 'query',
      'format': 'json',
      'formatversion': '2',
      'generator': 'geosearch',
      'ggscoord': '${town.lat}|${town.lng}',
      'ggsradius': '10000',
      'ggslimit': '40',
      'ggsnamespace': '6',
      'prop': 'imageinfo',
      'iiprop': 'url|size|mime|extmetadata',
      'iiurlwidth': '960',
      'iiextmetadatafilter': 'Artist|LicenseShortName',
    });
    return _photosFromImageInfoPages(await _getJson(uri), minWidth: 1000);
  }

  Future<List<TownPhoto>> _wikipediaGeoPagePhotos(TownModel town) async {
    final uri = Uri.https('es.wikipedia.org', '/w/api.php', {
      'action': 'query',
      'format': 'json',
      'formatversion': '2',
      'generator': 'geosearch',
      'ggscoord': '${town.lat}|${town.lng}',
      'ggsradius': '10000',
      'ggslimit': '12',
      'prop': 'pageimages',
      'piprop': 'thumbnail',
      'pithumbsize': '960',
      'pilimit': '12',
    });
    final json = await _getJson(uri);
    final pages = _pagesOf(json);
    final out = <TownPhoto>[];
    for (final page in pages) {
      final thumb = page['thumbnail'];
      if (thumb is! Map) continue;
      final url = thumb['source'] as String?;
      final title = page['title'] as String? ?? '';
      if (url == null || url.toLowerCase().contains('.svg') || _junkTitle.hasMatch(title)) {
        continue;
      }
      out.add(TownPhoto(
        url: url,
        thumbUrl: url,
        title: title,
        license: 'Wikipedia',
        source: 'Wikipedia',
        pageUrl: 'https://es.wikipedia.org/wiki/${Uri.encodeComponent(title.replaceAll(' ', '_'))}',
        width: (thumb['width'] as num?)?.toInt(),
        height: (thumb['height'] as num?)?.toInt(),
      ));
    }
    return out;
  }

  // ═══════════════════════════════════════════════════════════════════════
  //  FOTO DE UN PLATO TÍPICO
  // ═══════════════════════════════════════════════════════════════════════

  /// Intenta Wikipedia (título del plato) y luego una búsqueda en Commons.
  /// Puede devolver una imagen aproximada: la UI debe mostrar la atribución.
  Future<TownPhoto?> fetchDishPhoto(String plato) async {
    final name = plato.trim();
    if (name.isEmpty) return null;

    final fromWiki = await _safe<TownPhoto?>(() async {
      final title = name.replaceAll(' ', '_');
      final json = await _getJson(
          Uri.https('es.wikipedia.org', '/api/rest_v1/page/summary/$title'));
      if (json == null || json['type'] != 'standard') return null;
      final thumb = json['thumbnail'];
      final url = thumb is Map ? thumb['source'] as String? : null;
      if (url == null || url.toLowerCase().endsWith('.svg')) return null;
      return TownPhoto(
        url: url,
        thumbUrl: url,
        title: (json['title'] as String?) ?? name,
        license: 'Wikipedia',
        source: 'Wikimedia Commons',
        pageUrl: ((json['content_urls'] as Map?)?['desktop'] as Map?)?['page']
            as String?,
        width: (thumb['width'] as num?)?.toInt(),
        height: (thumb['height'] as num?)?.toInt(),
      );
    }, fallback: null);
    if (fromWiki != null) return fromWiki;

    return _safe<TownPhoto?>(() async {
      final uri = Uri.https('commons.wikimedia.org', '/w/api.php', {
        'action': 'query',
        'format': 'json',
        'formatversion': '2',
        'generator': 'search',
        'gsrnamespace': '6',
        'gsrsearch': '$name filetype:bitmap',
        'gsrlimit': '6',
        'prop': 'imageinfo',
        'iiprop': 'url|size|mime|extmetadata',
        'iiurlwidth': '640',
        'iiextmetadatafilter': 'Artist|LicenseShortName',
      });
      final photos =
          _photosFromImageInfoPages(await _getJson(uri), minWidth: 500);
      return photos.isEmpty ? null : photos.first;
    }, fallback: null);
  }

  // ═══════════════════════════════════════════════════════════════════════
  //  GOOGLE PLACES API (NEW) — opcional
  // ═══════════════════════════════════════════════════════════════════════

  static const String _placesFieldMask = 'places.id,places.displayName,'
      'places.formattedAddress,places.rating,places.userRatingCount,'
      'places.location,places.photos,places.currentOpeningHours.openNow,'
      'places.primaryTypeDisplayName,places.googleMapsUri';

  /// `places:searchNearby` y, si no hay resultados, `places:searchText`.
  Future<List<RoadsidePlace>> fetchRestaurants(
    TownModel town,
    String apiKey, {
    double radiusMeters = 6000,
    int maxResults = 8,
  }) async {
    final nearby = await searchNearby(town, apiKey,
        radiusMeters: radiusMeters, maxResults: maxResults);
    if (nearby.isNotEmpty) return nearby;
    return searchText(town, apiKey,
        radiusMeters: radiusMeters, maxResults: maxResults);
  }

  Future<List<RoadsidePlace>> searchNearby(
    TownModel town,
    String apiKey, {
    double radiusMeters = 6000,
    int maxResults = 8,
  }) async {
    final body = {
      'includedTypes': ['restaurant'],
      'maxResultCount': maxResults,
      'languageCode': 'es',
      'rankPreference': 'POPULARITY',
      'locationRestriction': {
        'circle': {
          'center': {'latitude': town.lat, 'longitude': town.lng},
          'radius': radiusMeters,
        },
      },
    };
    return _placesRequest('places:searchNearby', apiKey, body, town);
  }

  Future<List<RoadsidePlace>> searchText(
    TownModel town,
    String apiKey, {
    double radiusMeters = 8000,
    int maxResults = 8,
  }) async {
    final body = {
      'textQuery':
          'restaurantes y paraderos en ${town.nombreLugar}, ${town.departamento}, Perú',
      'maxResultCount': maxResults,
      'languageCode': 'es',
      'locationBias': {
        'circle': {
          'center': {'latitude': town.lat, 'longitude': town.lng},
          'radius': radiusMeters,
        },
      },
    };
    return _placesRequest('places:searchText', apiKey, body, town);
  }

  /// Prueba rápida de la clave (botón "Probar conexión" de Ajustes).
  Future<void> testPlacesKey(String apiKey) async {
    final body = {
      'textQuery': 'restaurante Lima Perú',
      'maxResultCount': 1,
      'languageCode': 'es',
    };
    await _placesRequest(
        'places:searchText', apiKey, body, null, fieldMask: 'places.id');
  }

  Future<List<RoadsidePlace>> _placesRequest(
    String method,
    String apiKey,
    Map<String, dynamic> body,
    TownModel? town, {
    String fieldMask = _placesFieldMask,
  }) async {
    if (apiKey.trim().isEmpty) {
      throw const PlacesApiException('Falta la API Key de Google Places.');
    }
    try {
      final res = await _client
          .post(
            Uri.https('places.googleapis.com', '/v1/$method'),
            headers: {
              'Content-Type': 'application/json',
              'X-Goog-Api-Key': apiKey.trim(),
              'X-Goog-FieldMask': fieldMask,
            },
            body: jsonEncode(body),
          )
          .timeout(AppConstants.httpTimeout);

      final decoded = jsonDecode(utf8.decode(res.bodyBytes));
      if (res.statusCode != 200) {
        var msg = 'Google Places respondió ${res.statusCode}.';
        if (decoded is Map && decoded['error'] is Map) {
          msg = ((decoded['error'] as Map)['message'] ?? msg).toString();
        }
        throw PlacesApiException(msg);
      }
      if (decoded is! Map || decoded['places'] is! List) return const [];

      final out = <RoadsidePlace>[];
      for (final raw in decoded['places'] as List) {
        if (raw is! Map) continue;
        final p = Map<String, dynamic>.from(raw);
        final loc = p['location'] as Map?;
        final lat = (loc?['latitude'] as num?)?.toDouble();
        final lng = (loc?['longitude'] as num?)?.toDouble();
        final photos = p['photos'];
        String? photoUrl;
        if (photos is List && photos.isNotEmpty && photos.first is Map) {
          final name = (photos.first as Map)['name'] as String?;
          if (name != null) photoUrl = placePhotoUrl(name, apiKey.trim());
        }
        out.add(RoadsidePlace(
          id: (p['id'] as String?) ?? '',
          nombre: ((p['displayName'] as Map?)?['text'] as String?) ?? 'Sin nombre',
          direccion: p['formattedAddress'] as String?,
          rating: (p['rating'] as num?)?.toDouble(),
          ratingCount: (p['userRatingCount'] as num?)?.toInt(),
          abiertoAhora:
              (p['currentOpeningHours'] as Map?)?['openNow'] as bool?,
          photoUrl: photoUrl,
          lat: lat,
          lng: lng,
          tipo: ((p['primaryTypeDisplayName'] as Map?)?['text']) as String?,
          mapsUrl: p['googleMapsUri'] as String?,
          distanciaKm: (town != null && lat != null && lng != null)
              ? OfflineGeocoderService.haversineKm(town.lat, town.lng, lat, lng)
              : null,
        ));
      }
      return out;
    } on PlacesApiException {
      rethrow;
    } on TimeoutException {
      throw const PlacesApiException('Google Places tardó demasiado en responder.');
    } on SocketException {
      throw const PlacesApiException('Sin conexión a internet.');
    } on http.ClientException {
      throw const PlacesApiException('Sin conexión a internet.');
    } on FormatException {
      throw const PlacesApiException('Respuesta inválida de Google Places.');
    }
  }

  /// URL de foto de Google Places (devuelve 302 a la imagen real).
  static String placePhotoUrl(String photoName, String apiKey,
          {int maxWidth = 800}) =>
      'https://places.googleapis.com/v1/$photoName/media'
      '?maxWidthPx=$maxWidth&key=$apiKey';

  // ═══════════════════════════════════════════════════════════════════════
  //  UTILIDADES
  // ═══════════════════════════════════════════════════════════════════════

  Future<T> _safe<T>(Future<T> Function() action, {T? fallback}) async {
    try {
      return await action();
    } catch (_) {
      if (fallback is T) return fallback;
      return <TownPhoto>[] as T;
    }
  }

  Future<Map<String, dynamic>?> _getJson(Uri uri) async {
    try {
      final res =
          await _client.get(uri, headers: _wikiHeaders).timeout(AppConstants.httpTimeout);
      if (res.statusCode != 200) return null;
      final decoded = jsonDecode(utf8.decode(res.bodyBytes));
      return decoded is Map<String, dynamic> ? decoded : null;
    } on TimeoutException {
      return null;
    } on SocketException {
      return null;
    } on http.ClientException {
      return null;
    } on FormatException {
      return null;
    }
  }

  List<Map<String, dynamic>> _pagesOf(Map<String, dynamic>? json) {
    final pages = (json?['query'] as Map?)?['pages'];
    if (pages is! List) return const [];
    final list = pages.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
    list.sort((a, b) =>
        ((a['index'] as num?) ?? 9999).compareTo((b['index'] as num?) ?? 9999));
    return list;
  }

  List<TownPhoto> _photosFromImageInfoPages(Map<String, dynamic>? json,
      {required int minWidth}) {
    final out = <TownPhoto>[];
    for (final page in _pagesOf(json)) {
      final infos = page['imageinfo'];
      if (infos is! List || infos.isEmpty || infos.first is! Map) continue;
      final info = Map<String, dynamic>.from(infos.first as Map);

      final mime = info['mime'] as String? ?? '';
      if (mime != 'image/jpeg' && mime != 'image/png') continue;
      final width = (info['width'] as num?)?.toInt() ?? 0;
      final height = (info['height'] as num?)?.toInt() ?? 0;
      if (width < minWidth || height < 400) continue;

      final rawTitle = (page['title'] as String? ?? '').replaceFirst('File:', '');
      if (_junkTitle.hasMatch(rawTitle)) continue;

      final url = (info['thumburl'] ?? info['url']) as String?;
      if (url == null) continue;

      final meta = info['extmetadata'];
      final author = meta is Map ? _stripHtml(meta['Artist']?['value']) : null;
      final license =
          meta is Map ? _stripHtml(meta['LicenseShortName']?['value']) : null;

      out.add(TownPhoto(
        url: url,
        thumbUrl: url,
        title: rawTitle.replaceAll(RegExp(r'\.[A-Za-z]{3,4}$'), '').replaceAll('_', ' '),
        author: (author == null || author.isEmpty) ? null : author,
        license: (license == null || license.isEmpty) ? null : license,
        source: 'Wikimedia Commons',
        pageUrl: info['descriptionurl'] as String?,
        width: (info['thumbwidth'] as num?)?.toInt() ?? width,
        height: (info['thumbheight'] as num?)?.toInt() ?? height,
      ));
    }
    return out;
  }

  String? _stripHtml(dynamic value) {
    if (value is! String) return null;
    return value
        .replaceAll(RegExp(r'<[^>]*>'), '')
        .replaceAll('&amp;', '&')
        .replaceAll('&quot;', '"')
        .replaceAll('&#039;', "'")
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  void dispose() => _client.close();
}
