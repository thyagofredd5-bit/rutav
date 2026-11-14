import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:http/http.dart' as http;

import '../core/app_constants.dart';
import '../models/geo_models.dart';
import 'routing_service.dart';

/// Buscador unificado de lugares del Perú (estilo Google Maps).
/// Consulta EN PARALELO: catálogo offline (0 ms) + Photon (Komoot) + Nominatim,
/// y mezcla los resultados sin duplicados (offline → Photon → Nominatim).
class LocationResolverService {
  LocationResolverService({http.Client? client, NominatimService? nominatim})
      : _client = client ?? http.Client(),
        _ownsClient = client == null,
        _nominatim = nominatim ?? NominatimService(),
        _ownsNominatim = nominatim == null;

  final http.Client _client;
  final bool _ownsClient;
  final NominatimService _nominatim;
  final bool _ownsNominatim;

  static const Duration _sourceTimeout = Duration(seconds: 8);

  void dispose() {
    if (_ownsClient) _client.close();
    if (_ownsNominatim) _nominatim.dispose();
  }

  /// Sin tildes, minúsculas y espacios simples: "Plaza San Martín" == "plaza san martin".
  static String normalize(String input) {
    const from = 'áéíóúüñàèìòùâêîôû';
    const to = 'aeiouunaeiouaeiou';
    var t = input.toLowerCase();
    for (var i = 0; i < from.length; i++) {
      t = t.replaceAll(from[i], to[i]);
    }
    return t.replaceAll(RegExp(r'[^a-z0-9]+'), ' ').trim();
  }

  /// Coincidencias inmediatas del catálogo offline.
  List<GeoPlace> searchOffline(String query) {
    final q = normalize(query);
    if (q.length < 2) return const <GeoPlace>[];
    final tokens = q.split(' ').where((e) => e.isNotEmpty).toList();
    final out = <GeoPlace>[];
    for (final h in _catalog) {
      final hay = normalize('${h.name} ${h.province} ${h.department} ${h.alias}');
      if (tokens.every(hay.contains)) {
        out.add(GeoPlace(
          id: GeoPlace.makeId(h.name, h.department),
          name: h.name,
          lat: h.lat,
          lng: h.lng,
          province: h.province,
          department: h.department,
        ));
      }
    }
    return out;
  }

  Future<List<GeoPlace>> search(String query) async {
    final q = query.trim();
    if (q.length < 2) return const <GeoPlace>[];

    final offline = searchOffline(q);
    if (q.length < 3) return offline;

    final remote = await Future.wait<List<GeoPlace>>([
      _safe(() => _photon(q)),
      _safe(() => _nominatim.search(q)),
    ]);

    final out = <GeoPlace>[];
    final seen = <String>{};
    final seenNear = <String>[];
    void add(GeoPlace p) {
      if (!seen.add(p.id)) return;
      // Evita duplicados casi idénticos (mismo nombre a < 1 km).
      final key = normalize(p.name);
      for (final s in seenNear) {
        final parts = s.split('|');
        if (parts[0] == key) {
          final d = _approxKm(double.parse(parts[1]), double.parse(parts[2]), p.lat, p.lng);
          if (d < 1.0) return;
        }
      }
      seenNear.add('$key|${p.lat}|${p.lng}');
      out.add(p);
    }

    for (final p in offline) {
      add(p);
    }
    for (final list in remote) {
      for (final p in list) {
        add(p);
      }
    }
    return out.take(10).toList();
  }

  Future<List<GeoPlace>> _safe(Future<List<GeoPlace>> Function() f) async {
    try {
      return await f().timeout(_sourceTimeout);
    } catch (_) {
      return const <GeoPlace>[];
    }
  }

  static double _approxKm(double lat1, double lng1, double lat2, double lng2) {
    final dx = (lng1 - lng2) * 111.0;
    final dy = (lat1 - lat2) * 111.0;
    return math.sqrt(dx * dx + dy * dy);
  }

  /// Photon (Komoot, datos OSM) con sesgo hacia Lima; solo resultados de Perú.
  Future<List<GeoPlace>> _photon(String q) async {
    final uri = Uri.https('photon.komoot.io', '/api/', {
      'q': q,
      'lat': '-12.0464',
      'lon': '-77.0428',
      'limit': '8',
    });
    final res = await _client.get(uri, headers: AppConstants.jsonHeaders);
    if (res.statusCode != 200) return const <GeoPlace>[];
    final decoded = jsonDecode(res.body);
    if (decoded is! Map) return const <GeoPlace>[];
    final features = decoded['features'];
    if (features is! List) return const <GeoPlace>[];

    String str(Map props, String key) {
      final v = props[key];
      if (v is String) return v.trim();
      return '';
    }

    final out = <GeoPlace>[];
    for (final f in features) {
      if (f is! Map) continue;
      final propsRaw = f['properties'];
      if (propsRaw is! Map) continue;
      if (str(propsRaw, 'countrycode').toUpperCase() != 'PE') continue;

      final geom = f['geometry'];
      double? lat;
      double? lng;
      if (geom is Map) {
        final c = geom['coordinates'];
        if (c is List && c.length >= 2) {
          lng = (c[0] as num).toDouble();
          lat = (c[1] as num).toDouble();
        }
      }
      if (lat == null || lng == null) continue;

      var name = str(propsRaw, 'name');
      if (name.isEmpty) name = str(propsRaw, 'street');
      if (name.isEmpty) name = str(propsRaw, 'district');
      if (name.isEmpty) continue;

      var province = '';
      for (final k in const ['county', 'city', 'district']) {
        final v = str(propsRaw, k);
        if (v.isNotEmpty && v.toLowerCase() != name.toLowerCase()) {
          province = v;
          break;
        }
      }
      var department = str(propsRaw, 'state');
      for (final prefix in const ['Departamento de ', 'Región ', 'Region ']) {
        if (department.toLowerCase().startsWith(prefix.toLowerCase())) {
          department = department.substring(prefix.length).trim();
        }
      }

      out.add(GeoPlace(
        id: GeoPlace.makeId(name, department),
        name: name,
        lat: lat,
        lng: lng,
        province: province,
        department: department,
      ));
    }
    return out;
  }
}

class _Hito {
  const _Hito(this.name, this.province, this.department, this.lat, this.lng,
      [this.alias = '']);
  final String name;
  final String province;
  final String department;
  final double lat;
  final double lng;
  final String alias;
}

/// Hitos principales (respuesta en 0 ms, sin red).
const List<_Hito> _catalog = [
  _Hito('Plaza San Martín', 'Lima', 'Lima', -12.0519, -77.0343, 'centro de lima'),
  _Hito('Estadio Nacional', 'Lima', 'Lima', -12.0672, -77.0334, 'santa beatriz'),
  _Hito('Surquillo', 'Lima', 'Lima', -12.1117, -77.0156),
  _Hito('Miraflores', 'Lima', 'Lima', -12.1211, -77.0297),
  _Hito('Centro Histórico de Arequipa', 'Arequipa', 'Arequipa', -16.3989, -71.5369,
      'plaza de armas'),
  _Hito('Sachaca', 'Arequipa', 'Arequipa', -16.4294, -71.5628),
  _Hito('Yanahuara', 'Arequipa', 'Arequipa', -16.3883, -71.5461),
  _Hito('Cusco', 'Cusco', 'Cusco', -13.5164, -71.9785, 'cuzco plaza de armas'),
  _Hito('Puno', 'Puno', 'Puno', -15.8402, -70.0219),
  _Hito('Ica', 'Ica', 'Ica', -14.0678, -75.7286),
  _Hito('Cajamarca', 'Cajamarca', 'Cajamarca', -7.1638, -78.5003),
  _Hito('Trujillo', 'Trujillo', 'La Libertad', -8.1116, -79.0288),
  _Hito('Tacna', 'Tacna', 'Tacna', -18.0066, -70.2463),
];
