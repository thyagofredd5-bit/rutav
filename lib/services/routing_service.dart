import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:http/http.dart' as http;

import '../core/app_constants.dart';
import '../models/geo_models.dart';
import '../models/town_model.dart';
import 'offline_geocoder_service.dart';

class RoutingException implements Exception {
  const RoutingException(this.message);
  final String message;
  @override
  String toString() => message;
}

class GeoPoint {
  const GeoPoint(this.lat, this.lng);
  final double lat;
  final double lng;
}

/// Ruta por carretera ya simplificada (≤ ~900 puntos) con km acumulados.
class RoutePlan {
  const RoutePlan({
    required this.origin,
    required this.destination,
    required this.lats,
    required this.lngs,
    required this.cumKm,
    required this.totalKm,
    required this.durationMin,
  });

  final GeoPlace origin;
  final GeoPlace destination;
  final List<double> lats;
  final List<double> lngs;
  final List<double> cumKm;
  final double totalKm;
  final double durationMin;

  int get length => lats.length;

  static double _r(double v, int d) => double.parse(v.toStringAsFixed(d));

  Map<String, dynamic> toJson() => {
        'origin': origin.toJson(),
        'destination': destination.toJson(),
        'lat': [for (final v in lats) _r(v, 5)],
        'lng': [for (final v in lngs) _r(v, 5)],
        'km': [for (final v in cumKm) _r(v, 3)],
        'totalKm': totalKm,
        'durationMin': durationMin,
      };

  factory RoutePlan.fromJson(Map<String, dynamic> j) {
    List<double> list(Object? raw) {
      if (raw is List) return [for (final v in raw) (v as num).toDouble()];
      return <double>[];
    }

    return RoutePlan(
      origin: GeoPlace.fromJson(Map<String, dynamic>.from(j['origin'] as Map)),
      destination:
          GeoPlace.fromJson(Map<String, dynamic>.from(j['destination'] as Map)),
      lats: list(j['lat']),
      lngs: list(j['lng']),
      cumKm: list(j['km']),
      totalKm: (j['totalKm'] as num?)?.toDouble() ?? 0,
      durationMin: (j['durationMin'] as num?)?.toDouble() ?? 0,
    );
  }

  String encode() => jsonEncode(toJson());

  static RoutePlan? tryDecode(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      return RoutePlan.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }
}

class RouteMatch {
  const RouteMatch({
    required this.alongKm,
    required this.offRouteKm,
    required this.segment,
  });
  final double alongKm;
  final double offRouteKm;
  final int segment;
}

/// Proyecta coordenadas GPS sobre la polilínea de la ruta (offline).
class RouteTracker {
  RouteTracker(this.plan);
  final RoutePlan plan;

  RouteMatch match(double lat, double lng, {int fromSegment = 0}) {
    final n = plan.length;
    if (n < 2) return const RouteMatch(alongKm: 0, offRouteKm: 0, segment: 0);
    final start = fromSegment.clamp(0, n - 2).toInt();
    final cosLat = math.cos(lat * math.pi / 180);
    var best = double.infinity;
    var bestAlong = 0.0;
    var bestSeg = start;
    for (var i = start; i < n - 1; i++) {
      final ax = (plan.lngs[i] - lng) * cosLat * 111.32;
      final ay = (plan.lats[i] - lat) * 110.574;
      final bx = (plan.lngs[i + 1] - lng) * cosLat * 111.32;
      final by = (plan.lats[i + 1] - lat) * 110.574;
      final dx = bx - ax;
      final dy = by - ay;
      final len2 = dx * dx + dy * dy;
      var t = len2 == 0 ? 0.0 : (-(ax * dx + ay * dy)) / len2;
      t = t.clamp(0.0, 1.0).toDouble();
      final px = ax + t * dx;
      final py = ay + t * dy;
      final d = math.sqrt(px * px + py * py);
      if (d < best) {
        best = d;
        bestSeg = i;
        bestAlong = plan.cumKm[i] + t * (plan.cumKm[i + 1] - plan.cumKm[i]);
      }
    }
    return RouteMatch(alongKm: bestAlong, offRouteKm: best, segment: bestSeg);
  }

  GeoPoint pointAtKm(double km) {
    final n = plan.length;
    if (n == 0) return GeoPoint(plan.destination.lat, plan.destination.lng);
    if (n == 1) return GeoPoint(plan.lats[0], plan.lngs[0]);
    final k = km.clamp(0.0, plan.totalKm).toDouble();
    var lo = 0;
    var hi = n - 1;
    while (hi - lo > 1) {
      final mid = (lo + hi) >> 1;
      if (plan.cumKm[mid] <= k) {
        lo = mid;
      } else {
        hi = mid;
      }
    }
    final span = plan.cumKm[hi] - plan.cumKm[lo];
    final t = span <= 0 ? 0.0 : ((k - plan.cumKm[lo]) / span).clamp(0.0, 1.0).toDouble();
    return GeoPoint(
      plan.lats[lo] + t * (plan.lats[hi] - plan.lats[lo]),
      plan.lngs[lo] + t * (plan.lngs[hi] - plan.lngs[lo]),
    );
  }
}

// ═════════════════════════════════════════════════════════════════════════
//  NOMINATIM (OpenStreetMap)
// ═════════════════════════════════════════════════════════════════════════

class NominatimService {
  NominatimService({http.Client? client})
      : _client = client ?? http.Client(),
        _ownsClient = client == null;

  final http.Client _client;
  final bool _ownsClient;

  static Future<void> _gate = Future<void>.value();
  static DateTime _last = DateTime.fromMillisecondsSinceEpoch(0);
  static final Map<String, GeoPlace?> _cache = <String, GeoPlace?>{};

  void dispose() {
    if (_ownsClient) _client.close();
  }

  /// Política de uso de Nominatim: máximo 1 petición por segundo.
  static Future<T> _throttled<T>(Future<T> Function() action) {
    final completer = Completer<T>();
    _gate = _gate.then((_) async {
      final wait =
          const Duration(milliseconds: 1100) - DateTime.now().difference(_last);
      if (wait > Duration.zero) await Future<void>.delayed(wait);
      try {
        completer.complete(await action());
      } catch (e, st) {
        completer.completeError(e, st);
      } finally {
        _last = DateTime.now();
      }
    });
    return completer.future;
  }

  static const Map<String, String> _headers = AppConstants.jsonHeaders;

  Future<GeoPlace?> reverse(double lat, double lng,
      {int zoom = 14, int? altitudeM}) async {
    final key = '${lat.toStringAsFixed(2)},${lng.toStringAsFixed(2)}';
    if (_cache.containsKey(key)) {
      final hit = _cache[key];
      if (hit == null) return null;
      return altitudeM != null ? hit.copyWith(altitudeM: altitudeM) : hit;
    }
    try {
      final uri = Uri.https(AppConstants.nominatimHost, '/reverse', {
        'format': 'jsonv2',
        'lat': lat.toString(),
        'lon': lng.toString(),
        'zoom': zoom.toString(),
        'addressdetails': '1',
        'accept-language': 'es',
      });
      final res = await _throttled(
          () => _client.get(uri, headers: _headers).timeout(const Duration(seconds: 10)));
      if (res.statusCode != 200) return null;
      final decoded = jsonDecode(res.body);
      if (decoded is! Map) return null;
      if (decoded.containsKey('error')) return null;
      final place = _placeFromJson(Map<String, dynamic>.from(decoded),
          fallbackLat: lat, fallbackLng: lng);
      if (place == null) return null;
      if (_cache.length >= 200) _cache.remove(_cache.keys.first);
      _cache[key] = place;
      return altitudeM != null ? place.copyWith(altitudeM: altitudeM) : place;
    } catch (_) {
      return null;
    }
  }

  Future<List<GeoPlace>> search(String query, {int limit = 6}) async {
    final q = query.trim();
    if (q.length < 3) return const <GeoPlace>[];
    try {
      final uri = Uri.https(AppConstants.nominatimHost, '/search', {
        'format': 'jsonv2',
        'q': '$q, Peru',
        'countrycodes': 'pe',
        'limit': limit.toString(),
        'addressdetails': '1',
        'accept-language': 'es',
      });
      final res = await _throttled(
          () => _client.get(uri, headers: _headers).timeout(const Duration(seconds: 10)));
      if (res.statusCode != 200) return const <GeoPlace>[];
      final decoded = jsonDecode(res.body);
      if (decoded is! List) return const <GeoPlace>[];
      final out = <GeoPlace>[];
      final seen = <String>{};
      for (final item in decoded) {
        if (item is! Map) continue;
        final p = _placeFromJson(Map<String, dynamic>.from(item));
        if (p == null) continue;
        if (seen.add(p.id)) out.add(p);
      }
      return out;
    } catch (_) {
      return const <GeoPlace>[];
    }
  }

  static String _s(Map<String, dynamic> a, String k) {
    final v = a[k];
    if (v is String) return v.trim();
    return '';
  }

  static String _clean(String raw) {
    var t = raw.trim();
    for (final prefix in const [
      'Departamento de ',
      'Provincia de ',
      'Distrito de ',
      'Región ',
      'Region ',
    ]) {
      if (t.toLowerCase().startsWith(prefix.toLowerCase())) {
        t = t.substring(prefix.length).trim();
      }
    }
    return t;
  }

  GeoPlace? _placeFromJson(Map<String, dynamic> j,
      {double? fallbackLat, double? fallbackLng}) {
    var address = <String, dynamic>{};
    final rawAddress = j['address'];
    if (rawAddress is Map) address = Map<String, dynamic>.from(rawAddress);

    final cc = _s(address, 'country_code');
    if (cc.isNotEmpty && cc.toLowerCase() != 'pe') return null;

    var name = '';
    for (final k in const [
      'suburb',
      'neighbourhood',
      'quarter',
      'city_district',
      'village',
      'hamlet',
      'town',
      'city',
      'municipality',
      'county',
    ]) {
      final v = _s(address, k);
      if (v.isNotEmpty) {
        name = v;
        break;
      }
    }
    if (name.isEmpty) name = _s(j, 'name');
    if (name.isEmpty) {
      final dn = _s(j, 'display_name');
      if (dn.isNotEmpty) name = dn.split(',').first.trim();
    }
    if (name.isEmpty) return null;

    var province = '';
    for (final k in const ['county', 'city', 'municipality', 'state_district']) {
      final v = _s(address, k);
      if (v.isNotEmpty && v.toLowerCase() != name.toLowerCase()) {
        province = _clean(v);
        break;
      }
    }

    var department = _s(address, 'state');
    if (department.isEmpty) department = _s(address, 'region');
    department = _clean(department);

    final lat = double.tryParse(_s(j, 'lat')) ?? fallbackLat;
    final lng = double.tryParse(_s(j, 'lon')) ?? fallbackLng;
    if (lat == null || lng == null) return null;

    return GeoPlace(
      id: GeoPlace.makeId(name, department),
      name: name,
      lat: lat,
      lng: lng,
      province: province,
      department: department,
    );
  }
}

// ═════════════════════════════════════════════════════════════════════════
//  OSRM
// ═════════════════════════════════════════════════════════════════════════

class OsrmService {
  OsrmService({http.Client? client})
      : _client = client ?? http.Client(),
        _ownsClient = client == null;

  final http.Client _client;
  final bool _ownsClient;

  void dispose() {
    if (_ownsClient) _client.close();
  }

  Future<RoutePlan> route({
    required GeoPlace origin,
    required GeoPlace destination,
  }) async {
    final uri = Uri.https(
      AppConstants.osrmHost,
      '/route/v1/driving/${origin.lng},${origin.lat};${destination.lng},${destination.lat}',
      {'overview': 'full', 'geometries': 'geojson'},
    );

    http.Response res;
    try {
      res = await _client
          .get(uri, headers: AppConstants.jsonHeaders)
          .timeout(const Duration(seconds: 30));
    } catch (_) {
      throw const RoutingException(
          'No se pudo calcular la ruta. Revisa tu conexión e inténtalo de nuevo.');
    }
    if (res.statusCode != 200) {
      throw const RoutingException(
          'No se pudo calcular la ruta (servicio de rutas no disponible).');
    }

    Object? decoded;
    try {
      decoded = jsonDecode(res.body);
    } catch (_) {
      throw const RoutingException('No se pudo calcular la ruta (respuesta inválida).');
    }
    if (decoded is! Map) {
      throw const RoutingException('No se pudo calcular la ruta (respuesta inválida).');
    }
    final routes = decoded['routes'];
    if (routes is! List || routes.isEmpty || routes.first is! Map) {
      throw const RoutingException('No hay ruta por carretera entre esos puntos.');
    }
    final r0 = routes.first as Map;
    List<dynamic>? coords;
    final geometry = r0['geometry'];
    if (geometry is Map) {
      final c = geometry['coordinates'];
      if (c is List) coords = c;
    }
    if (coords == null || coords.length < 2) {
      throw const RoutingException('No hay ruta por carretera entre esos puntos.');
    }
    final distKm = ((r0['distance'] as num?)?.toDouble() ?? 0) / 1000.0;
    final durMin = ((r0['duration'] as num?)?.toDouble() ?? 0) / 60.0;

    final rawLats = <double>[];
    final rawLngs = <double>[];
    for (final c in coords) {
      if (c is List && c.length >= 2) {
        rawLngs.add((c[0] as num).toDouble());
        rawLats.add((c[1] as num).toDouble());
      }
    }
    if (rawLats.length < 2) {
      throw const RoutingException('No hay ruta por carretera entre esos puntos.');
    }

    var tol = 0.03;
    var keep = _simplify(rawLats, rawLngs, tol);
    while (keep.length > 900) {
      tol *= 2;
      keep = _simplify(rawLats, rawLngs, tol);
    }
    final lats = [for (final i in keep) rawLats[i]];
    final lngs = [for (final i in keep) rawLngs[i]];

    final cum = <double>[0.0];
    for (var i = 1; i < lats.length; i++) {
      cum.add(cum.last +
          OfflineGeocoderService.haversineKm(
              lats[i - 1], lngs[i - 1], lats[i], lngs[i]));
    }
    final geomKm = cum.last;
    final total = distKm > 0 ? distKm : geomKm;
    if (geomKm > 0) {
      final factor = total / geomKm;
      for (var i = 0; i < cum.length; i++) {
        cum[i] = cum[i] * factor;
      }
    }

    return RoutePlan(
      origin: origin,
      destination: destination,
      lats: lats,
      lngs: lngs,
      cumKm: cum,
      totalKm: total,
      durationMin: durMin,
    );
  }

  /// Ramer–Douglas–Peucker iterativo (pila explícita). Devuelve índices a conservar.
  static List<int> _simplify(List<double> lats, List<double> lngs, double tolKm) {
    final n = lats.length;
    if (n <= 2) return List<int>.generate(n, (i) => i);
    final cosLat = math.cos(lats[0] * math.pi / 180);
    final xs = List<double>.generate(n, (i) => lngs[i] * cosLat * 111.32);
    final ys = List<double>.generate(n, (i) => lats[i] * 110.574);
    final keep = List<bool>.filled(n, false);
    keep[0] = true;
    keep[n - 1] = true;
    final stack = <int>[0, n - 1];
    while (stack.isNotEmpty) {
      final e = stack.removeLast();
      final s = stack.removeLast();
      if (e - s < 2) continue;
      final dx = xs[e] - xs[s];
      final dy = ys[e] - ys[s];
      final len2 = dx * dx + dy * dy;
      var maxD = 0.0;
      var idx = -1;
      for (var i = s + 1; i < e; i++) {
        final px = xs[i] - xs[s];
        final py = ys[i] - ys[s];
        double d;
        if (len2 == 0) {
          d = math.sqrt(px * px + py * py);
        } else {
          final t = ((px * dx + py * dy) / len2).clamp(0.0, 1.0).toDouble();
          final qx = px - t * dx;
          final qy = py - t * dy;
          d = math.sqrt(qx * qx + qy * qy);
        }
        if (d > maxD) {
          maxD = d;
          idx = i;
        }
      }
      if (idx != -1 && maxD > tolKm) {
        keep[idx] = true;
        stack.addAll([s, idx, idx, e]);
      }
    }
    return [
      for (var i = 0; i < n; i++)
        if (keep[i]) i
    ];
  }
}

// ═════════════════════════════════════════════════════════════════════════
//  RESOLUCIÓN DE LUGARES (offline primero → Nominatim → respaldo)
// ═════════════════════════════════════════════════════════════════════════

class AheadPlace {
  const AheadPlace({required this.place, required this.distanceKm});
  final GeoPlace place;
  final double distanceKm;
}

class PlaceResolver {
  PlaceResolver({required this.geocoder, NominatimService? nominatim})
      : nominatim = nominatim ?? NominatimService(),
        _ownsNominatim = nominatim == null;

  final OfflineGeocoderService geocoder;
  final NominatimService nominatim;
  final bool _ownsNominatim;

  Future<GeoPlace> resolve(double lat, double lng, {double? altitudeM}) async {
    TownModel? nearest;
    var nearestKm = double.infinity;
    for (final t in geocoder.towns) {
      final d = OfflineGeocoderService.haversineKm(lat, lng, t.lat, t.lng);
      if (d < nearestKm) {
        nearestKm = d;
        nearest = t;
      }
    }

    // 1) Offline: localidad del JSON muy cercana.
    if (nearest != null && nearestKm <= AppConstants.offlinePlaceRadiusKm) {
      return GeoPlace(
        id: nearest.id,
        townId: nearest.id,
        name: nearest.nombre,
        province: nearest.provincia,
        department: nearest.departamento,
        lat: nearest.lat,
        lng: nearest.lng,
        altitudeM: nearest.msnm,
      );
    }

    // 2) Nominatim.
    final remote = await nominatim.reverse(lat, lng, altitudeM: altitudeM?.round());
    if (remote != null) return remote;

    // 3) Respaldo sin red.
    if (nearest != null && nearestKm <= 80) {
      return GeoPlace(
        id: GeoPlace.makeId('cerca de ${nearest.nombre}', nearest.departamento),
        name: 'Cerca de ${nearest.nombre}',
        province: nearest.provincia,
        department: nearest.departamento,
        lat: lat,
        lng: lng,
        altitudeM: altitudeM?.round() ?? nearest.msnm,
      );
    }
    return GeoPlace(
      id: 'geo:ubicacion-${lat.toStringAsFixed(2)}-${lng.toStringAsFixed(2)}',
      name: 'Ubicación ${lat.toStringAsFixed(3)}, ${lng.toStringAsFixed(3)}',
      lat: lat,
      lng: lng,
      altitudeM: altitudeM?.round(),
    );
  }

  /// Próximo distrito/pueblo por delante sobre la polilínea de la ruta.
  Future<AheadPlace?> placeAhead(
    RouteTracker tracker,
    double alongKm, {
    required String currentName,
    double stepKm = AppConstants.placeAheadKm,
    int maxTries = 4,
  }) async {
    final total = tracker.plan.totalKm;
    if (total - alongKm <= 1.0) return null;
    for (var k = 1; k <= maxTries; k++) {
      final km = alongKm + k * stepKm;
      if (km >= total) {
        return AheadPlace(
            place: tracker.plan.destination, distanceKm: total - alongKm);
      }
      final pt = tracker.pointAtKm(km);
      final place = await resolve(pt.lat, pt.lng);
      if (place.name.toLowerCase() != currentName.toLowerCase()) {
        return AheadPlace(place: place, distanceKm: km - alongKm);
      }
    }
    return AheadPlace(
        place: tracker.plan.destination, distanceKm: total - alongKm);
  }

  void dispose() {
    if (_ownsNominatim) nominatim.dispose();
  }
}
