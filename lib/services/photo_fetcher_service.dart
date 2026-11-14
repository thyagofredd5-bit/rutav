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

/// Fotos turísticas reales con filtrado estricto. Orden de prioridad:
///  1. Google Places (lugares turísticos en lat/lng) — si hay API Key.
///  2. Wikipedia geosearch (es + en) por coordenadas GPS.
///  3. Wikimedia Commons con filtro anti-personas/mascotas/mapas.
///  4. Respaldo por zona geográfica (según msnm), solo si no hubo nada válido.
///
/// Los métodos de fotos NUNCA lanzan excepciones: ante fallos de red devuelven
/// listas vacías para que la UI muestre el resto del contenido.
class PhotoFetcherService {
  PhotoFetcherService({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  static const Map<String, String> _wikiHeaders = {
    ...AppConstants.httpHeaders,
    'Api-User-Agent': AppConstants.httpUserAgent,
    'Accept': 'application/json',
  };

  /// Palabras prohibidas en título, descripción, categorías o URL.
  static final RegExp _banned = RegExp(
    r'\b(dogs?|perros?|cats?|gatos?|pets?|boys?|girls?|child|children|niñ[oa]s?|'
    r'persons?|people|portrait|selfie|maps?|mapa|locator|escudo|coat of arms|'
    r'flags?|bandera|logo)\b',
    caseSensitive: false,
  );

  static bool _isJunk(String? raw) {
    if (raw == null || raw.isEmpty) return false;
    var t = raw;
    try {
      t = Uri.decodeFull(raw);
    } catch (_) {}
    t = t.toLowerCase().replaceAll(RegExp(r'[_\-/+]'), ' ');
    return t.contains('.svg') || t.contains('.pdf') || _banned.hasMatch(t);
  }

  static String _norm(String s) {
    const from = 'áéíóúüñ';
    const to = 'aeiouun';
    var t = s.toLowerCase();
    for (var i = 0; i < from.length; i++) {
      t = t.replaceAll(from[i], to[i]);
    }
    return t.replaceAll('_', ' ');
  }

  /// URL de la página de escritorio (sin ternarios anidados: Dart 3).
  static String? _desktopPageUrl(Map<String, dynamic> json) {
    String? pageUrl;
    if (json['content_urls'] is Map &&
        (json['content_urls'] as Map)['desktop'] is Map) {
      pageUrl =
          ((json['content_urls'] as Map)['desktop'] as Map)['page']?.toString();
    }
    return pageUrl;
  }

  // ═══════════════════════════════════════════════════════════════════════
  //  FOTOS DEL PUEBLO
  // ═══════════════════════════════════════════════════════════════════════

  Future<List<TownPhoto>> fetchTownPhotos(
    TownModel town, {
    int maxPhotos = 8,
    String placesApiKey = '',
  }) async {
    final seen = <String>{};
    final out = <TownPhoto>[];

    void add(Iterable<TownPhoto> list) {
      for (final p in list) {
        if (out.length >= maxPhotos) return;
        if (p.url.isEmpty) continue;
        if (p.source != 'Google Places' && (_isJunk(p.url) || _isJunk(p.title))) {
          continue;
        }
        if (seen.add(p.url)) out.add(p);
      }
    }

    // V3: Places (si hay clave), Wikipedia es/en y Commons corren EN PARALELO;
    // cada fuente tiene su propio timeout (2.5 s) y el orden de prioridad se
    // conserva al combinar los resultados.
    final key = placesApiKey.trim();
    Future<List<TownPhoto>> raced(Future<List<TownPhoto>> Function() f,
            {Duration? timeout}) =>
        _safeList(f).timeout(timeout ?? AppConstants.photoSourceTimeout,
            onTimeout: () => const <TownPhoto>[]);

    final results = await Future.wait<List<TownPhoto>>([
      if (key.isNotEmpty)
        raced(() => _placesTouristPhotos(town, key),
            timeout: const Duration(seconds: 6)),
      raced(() => _wikipediaGeoPhotos(town, 'es')),
      raced(() => _wikipediaGeoPhotos(town, 'en')),
      raced(() => _commonsSearchPhotos(town)),
    ]);
    for (final l in results) {
      add(l);
    }
    // Prioridad 4: respaldo por zona geográfica.
    if (out.isEmpty) {
      add(await _safeList(() => _regionFallbackPhotos(town)));
    }
    return out;
  }

  // ── P1: Google Places ──────────────────────────────────────────────────

  Future<List<TownPhoto>> _placesTouristPhotos(
      TownModel town, String apiKey) async {
    final res = await _client
        .post(
          Uri.https('places.googleapis.com', '/v1/places:searchNearby'),
          headers: {
            'Content-Type': 'application/json',
            'X-Goog-Api-Key': apiKey,
            'X-Goog-FieldMask':
                'places.id,places.displayName,places.photos,places.googleMapsUri',
          },
          body: jsonEncode({
            'includedTypes': ['tourist_attraction', 'park'],
            'maxResultCount': 10,
            'languageCode': 'es',
            'rankPreference': 'POPULARITY',
            'locationRestriction': {
              'circle': {
                'center': {'latitude': town.lat, 'longitude': town.lng},
                'radius': 5000.0,
              },
            },
          }),
        )
        .timeout(AppConstants.httpTimeout);
    if (res.statusCode != 200) return const <TownPhoto>[];
    final decoded = jsonDecode(utf8.decode(res.bodyBytes));
    if (decoded is! Map || decoded['places'] is! List) return const <TownPhoto>[];

    final out = <TownPhoto>[];
    for (final raw in decoded['places'] as List) {
      if (raw is! Map) continue;
      final name = ((raw['displayName'] as Map?)?['text'] as String?) ?? '';
      final photos = raw['photos'];
      if (photos is! List) continue;
      var taken = 0;
      for (final ph in photos) {
        if (ph is! Map || taken >= 2) continue;
        final pname = ph['name'] as String?;
        final w = (ph['widthPx'] as num?)?.toInt();
        final h = (ph['heightPx'] as num?)?.toInt();
        if (pname == null) continue;
        if (w != null && h != null && w < h) continue; // solo horizontales
        String? author;
        final attrs = ph['authorAttributions'];
        if (attrs is List && attrs.isNotEmpty && attrs.first is Map) {
          author = (attrs.first as Map)['displayName']?.toString();
        }
        out.add(TownPhoto(
          url: placePhotoUrl(pname, apiKey, maxWidth: 1000),
          thumbUrl: placePhotoUrl(pname, apiKey, maxWidth: 800),
          title: name.isEmpty ? town.nombreLugar : name,
          author: author,
          source: 'Google Places',
          pageUrl: raw['googleMapsUri'] as String?,
          width: w,
          height: h,
        ));
        taken++;
      }
    }
    return out;
  }

  // ── P2: Wikipedia geosearch ────────────────────────────────────────────

  Future<List<TownPhoto>> _wikipediaGeoPhotos(TownModel town, String lang) async {
    final uri = Uri.https('$lang.wikipedia.org', '/w/api.php', {
      'action': 'query',
      'format': 'json',
      'formatversion': '2',
      'generator': 'geosearch',
      'ggscoord': '${town.lat}|${town.lng}',
      'ggsradius': '5000',
      'ggslimit': '20',
      'prop': 'pageimages',
      'piprop': 'thumbnail',
      'pithumbsize': '960',
      'pilimit': '20',
    });
    final json = await _getJson(uri);
    final out = <TownPhoto>[];
    for (final page in _pagesOf(json)) {
      final thumb = page['thumbnail'];
      if (thumb is! Map) continue;
      final url = thumb['source'] as String?;
      final title = page['title'] as String? ?? '';
      final w = (thumb['width'] as num?)?.toInt();
      final h = (thumb['height'] as num?)?.toInt();
      if (url == null || _isJunk(url) || _isJunk(title)) continue;
      if (w != null && w < 500) continue;
      out.add(TownPhoto(
        url: url,
        thumbUrl: url,
        title: title,
        license: 'Wikipedia',
        source: 'Wikipedia ($lang)',
        pageUrl:
            'https://$lang.wikipedia.org/wiki/${Uri.encodeComponent(title.replaceAll(' ', '_'))}',
        width: w,
        height: h,
      ));
    }
    return out;
  }

  // ── P3: Commons filtrado ───────────────────────────────────────────────

  Future<List<TownPhoto>> _commonsSearchPhotos(TownModel town) async {
    final uri = Uri.https('commons.wikimedia.org', '/w/api.php', {
      'action': 'query',
      'format': 'json',
      'formatversion': '2',
      'generator': 'search',
      'gsrnamespace': '6',
      'gsrsearch':
          '"${town.nombreLugar}" ${town.provincia} Peru (paisaje OR plaza OR mirador OR iglesia) filetype:bitmap',
      'gsrlimit': '30',
      'prop': 'imageinfo|categories',
      'cllimit': 'max',
      'iiprop': 'url|size|mime|extmetadata',
      'iiurlwidth': '960',
      'iiextmetadatafilter': 'Artist|LicenseShortName|ImageDescription|Categories',
    });
    return _photosFromImageInfoPages(
      await _getJson(uri),
      minWidth: 900,
      landscapeOnly: true,
      mustMention: town.nombreLugar,
    );
  }

  // ── P4: respaldo por zona (según altitud) ─────────────────────────────

  static List<String> _regionTitles(int msnm) {
    if (msnm < 500) {
      return const [
        'Reserva Nacional de Paracas',
        'Islas Ballestas',
        'Lomas de Lachay',
        'Reserva Nacional San Fernando',
      ];
    }
    if (msnm < 1800) {
      return const [
        'Huacachina',
        'Líneas de Nazca',
        'Valle de Majes',
        'Desierto de Ica',
      ];
    }
    if (msnm < 2800) {
      return const [
        'Misti',
        'Chachani',
        'Arequipa',
        'Centro histórico de Arequipa',
      ];
    }
    return const [
      'Cañón del Colca',
      'Ampato',
      'Coropuna',
      'Reserva Nacional de Salinas y Aguada Blanca',
    ];
  }

  /// Fotos reales de artículos emblemáticos de la zona (resueltas en línea
  /// desde Wikipedia para no depender de URLs fijas que podrían romperse).
  Future<List<TownPhoto>> _regionFallbackPhotos(TownModel town) async {
    final titles = _regionTitles(town.msnm);
    final results = await Future.wait<TownPhoto?>([
      for (final t in titles) _summaryPhoto(t),
    ]);
    return [
      for (final p in results)
        if (p != null) p,
    ];
  }

  Future<TownPhoto?> _summaryPhoto(String title, {String lang = 'es'}) async {
    try {
      final json = await _getJson(Uri.https('$lang.wikipedia.org',
          '/api/rest_v1/page/summary/${title.replaceAll(' ', '_')}'));
      if (json == null || json['type'] != 'standard') return null;
      final original = json['originalimage'];
      final thumb = json['thumbnail'];
      String? url;
      int? w;
      int? h;
      if (original is Map && ((original['width'] as num?) ?? 99999) <= 2000) {
        url = original['source'] as String?;
        w = (original['width'] as num?)?.toInt();
        h = (original['height'] as num?)?.toInt();
      } else if (thumb is Map) {
        url = thumb['source'] as String?;
        w = (thumb['width'] as num?)?.toInt();
        h = (thumb['height'] as num?)?.toInt();
      }
      if (url == null || _isJunk(url)) return null;

      String? pageUrl;
      if (json['content_urls'] is Map &&
          (json['content_urls'] as Map)['desktop'] is Map) {
        pageUrl =
            ((json['content_urls'] as Map)['desktop'] as Map)['page']?.toString();
      }
      return TownPhoto(
        url: url,
        thumbUrl: thumb is Map ? thumb['source'] as String? : null,
        title: (json['title'] as String?) ?? title,
        license: 'Wikipedia',
        source: 'Wikipedia',
        pageUrl: pageUrl,
        width: w,
        height: h,
      );
    } catch (_) {
      return null;
    }
  }

  // ═══════════════════════════════════════════════════════════════════════
  //  FOTO DE UN PLATO TÍPICO
  // ═══════════════════════════════════════════════════════════════════════

  Future<TownPhoto?> fetchDishPhoto(String plato) async {
    final name = plato.trim();
    if (name.isEmpty) return null;

    final fromWiki = await _summaryPhoto(name);
    if (fromWiki != null && !_isJunk(fromWiki.title)) return fromWiki;

    try {
      final uri = Uri.https('commons.wikimedia.org', '/w/api.php', {
        'action': 'query',
        'format': 'json',
        'formatversion': '2',
        'generator': 'search',
        'gsrnamespace': '6',
        'gsrsearch': '$name comida filetype:bitmap',
        'gsrlimit': '8',
        'prop': 'imageinfo|categories',
        'cllimit': 'max',
        'iiprop': 'url|size|mime|extmetadata',
        'iiurlwidth': '500',
        'iiextmetadatafilter': 'Artist|LicenseShortName|ImageDescription|Categories',
      });
      final photos = _photosFromImageInfoPages(await _getJson(uri),
          minWidth: 500, mustMention: name.split(' ').first);
      return photos.isEmpty ? null : photos.first;
    } catch (_) {
      return null;
    }
  }

  // ═══════════════════════════════════════════════════════════════════════
  //  GOOGLE PLACES API (NEW) — restaurantes (opcional)
  // ═══════════════════════════════════════════════════════════════════════

  static const String _placesFieldMask = 'places.id,places.displayName,'
      'places.formattedAddress,places.rating,places.userRatingCount,'
      'places.location,places.photos,places.currentOpeningHours.openNow,'
      'places.primaryTypeDisplayName,places.googleMapsUri';

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

  Future<void> testPlacesKey(String apiKey) async {
    final body = {
      'textQuery': 'restaurante Lima Perú',
      'maxResultCount': 1,
      'languageCode': 'es',
    };
    await _placesRequest('places:searchText', apiKey, body, null,
        fieldMask: 'places.id');
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
          abiertoAhora: (p['currentOpeningHours'] as Map?)?['openNow'] as bool?,
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

  Future<List<TownPhoto>> _safeList(
      Future<List<TownPhoto>> Function() action) async {
    try {
      return await action();
    } catch (_) {
      return const <TownPhoto>[];
    }
  }

  Future<Map<String, dynamic>?> _getJson(Uri uri) async {
    try {
      final res = await _client
          .get(uri, headers: _wikiHeaders)
          .timeout(AppConstants.httpTimeout);
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
    final list =
        pages.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
    list.sort((a, b) =>
        ((a['index'] as num?) ?? 9999).compareTo((b['index'] as num?) ?? 9999));
    return list;
  }

  List<TownPhoto> _photosFromImageInfoPages(
    Map<String, dynamic>? json, {
    required int minWidth,
    bool landscapeOnly = false,
    String? mustMention,
  }) {
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
      if (landscapeOnly && width < height * 1.1) continue;

      final rawTitle = (page['title'] as String? ?? '').replaceFirst('File:', '');
      final meta = info['extmetadata'];
      String? field(String k) {
        if (meta is Map && meta[k] is Map) {
          return _stripHtml((meta[k] as Map)['value']);
        }
        return null;
      }

      final desc = field('ImageDescription') ?? '';
      final cats = field('Categories') ?? '';
      final catTitles = page['categories'] is List
          ? (page['categories'] as List)
              .whereType<Map>()
              .map((c) => (c['title'] ?? '').toString())
              .join(' ')
          : '';
      final haystack = '$rawTitle $desc $cats $catTitles';
      if (_isJunk(haystack)) continue;
      if (mustMention != null &&
          !_norm(haystack).contains(_norm(mustMention))) {
        continue;
      }

      final url = (info['thumburl'] ?? info['url']) as String?;
      if (url == null || _isJunk(url)) continue;

      final author = field('Artist');
      final license = field('LicenseShortName');

      out.add(TownPhoto(
        url: url,
        thumbUrl: url,
        title: rawTitle
            .replaceAll(RegExp(r'\.[A-Za-z]{3,4}$'), '')
            .replaceAll('_', ' '),
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
