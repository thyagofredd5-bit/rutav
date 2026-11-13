import 'town_model.dart';

/// Modo de seguimiento del viaje.
enum TripMode {
  corridor('Corredor Lima–Arequipa'),
  custom('Viaje a un destino'),
  free('Explorador libre');

  const TripMode(this.label);
  final String label;

  static TripMode parse(String? raw) => TripMode.values.firstWhere(
        (e) => e.name == raw,
        orElse: () => TripMode.corridor,
      );
}

/// Lugar resuelto (distrito, barrio, pueblo o destino elegido por el usuario).
class GeoPlace {
  const GeoPlace({
    required this.id,
    required this.name,
    required this.lat,
    required this.lng,
    this.province = '',
    this.department = '',
    this.altitudeM,
    this.townId,
  });

  /// `geo:<nombre>-<departamento>` (estable: sirve de clave de caché) o el id
  /// del JSON offline cuando el lugar es una localidad del corredor.
  final String id;
  final String name;
  final double lat;
  final double lng;
  final String province;
  final String department;
  final int? altitudeM;

  /// Id de la localidad del JSON offline si se resolvió sin red.
  final String? townId;

  static String _slug(String s) {
    const from = 'áéíóúüñàèìòùâêîôû';
    const to = 'aeiouunaeiouaeiou';
    var t = s.toLowerCase();
    for (var i = 0; i < from.length; i++) {
      t = t.replaceAll(from[i], to[i]);
    }
    t = t.replaceAll(RegExp(r'[^a-z0-9]+'), '-');
    t = t.replaceAll(RegExp(r'^-+|-+$'), '');
    return t;
  }

  static String makeId(String name, String department) {
    final n = _slug(name);
    final d = _slug(department);
    return d.isEmpty ? 'geo:$n' : 'geo:$n-$d';
  }

  String get subtitle {
    final parts = <String>[];
    for (final raw in [province, department]) {
      final v = raw.trim();
      if (v.isEmpty) continue;
      if (parts.any((e) => e.toLowerCase() == v.toLowerCase())) continue;
      parts.add(v);
    }
    return parts.join(', ');
  }

  bool get isOfflineTown => townId != null;

  GeoPlace copyWith({int? altitudeM, double? lat, double? lng}) => GeoPlace(
        id: id,
        name: name,
        lat: lat ?? this.lat,
        lng: lng ?? this.lng,
        province: province,
        department: department,
        altitudeM: altitudeM ?? this.altitudeM,
        townId: townId,
      );

  /// Ficha sintética para reutilizar fotos/IA/caché pensadas para [TownModel].
  TownModel toTownModel() => TownModel(
        id: id,
        orden: 0,
        nombre: name,
        provincia: province,
        departamento: department,
        lat: lat,
        lng: lng,
        msnm: altitudeM ?? 0,
        kmRuta: 0,
        tipo: TownType.distrito,
        etiqueta: subtitle,
        enRutaPrincipal: false,
        desvioKm: 0,
        wikipedia: null,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'lat': lat,
        'lng': lng,
        'province': province,
        'department': department,
        'altitudeM': altitudeM,
        'townId': townId,
      };

  factory GeoPlace.fromJson(Map<String, dynamic> j) => GeoPlace(
        id: j['id'] as String? ?? '',
        name: j['name'] as String? ?? '',
        lat: (j['lat'] as num?)?.toDouble() ?? 0,
        lng: (j['lng'] as num?)?.toDouble() ?? 0,
        province: j['province'] as String? ?? '',
        department: j['department'] as String? ?? '',
        altitudeM: (j['altitudeM'] as num?)?.toInt(),
        townId: j['townId'] as String?,
      );
}
