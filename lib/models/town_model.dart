import 'dart:convert';

/// Tipo de localidad dentro de la ruta.
enum TownType {
  ciudad('Ciudad'),
  pueblo('Pueblo'),
  balneario('Balneario'),
  caleta('Caleta'),
  cruce('Cruce'),
  desvio('Desvío'),
  distrito('Distrito');

  const TownType(this.label);
  final String label;

  static TownType parse(String? raw) => TownType.values.firstWhere(
        (e) => e.name == raw,
        orElse: () => TownType.pueblo,
      );
}

/// Localidad real de la carretera (fila de `assets/data/rutas_peru.json`).
class TownModel {
  const TownModel({
    required this.id,
    required this.orden,
    required this.nombre,
    required this.provincia,
    required this.departamento,
    required this.lat,
    required this.lng,
    required this.msnm,
    required this.kmRuta,
    required this.tipo,
    required this.etiqueta,
    required this.enRutaPrincipal,
    required this.desvioKm,
    this.wikipedia,
  });

  final String id;
  final int orden;
  final String nombre;
  final String provincia;
  final String departamento;
  final double lat;
  final double lng;

  /// Altitud en metros sobre el nivel del mar.
  final int msnm;

  /// Kilómetro aproximado por carretera desde Lima Centro.
  final double kmRuta;
  final TownType tipo;
  final String etiqueta;

  /// `false` para puntos fuera de la carretera (p. ej. Ocucaje).
  final bool enRutaPrincipal;

  /// Distancia del desvío respecto a la carretera principal (0 si está sobre ella).
  final double desvioKm;

  /// Título exacto del artículo en es.wikipedia.org (para fotos y resumen).
  final String? wikipedia;

  factory TownModel.fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    if (id is! String || id.isEmpty) {
      throw const FormatException('Localidad sin "id" válido.');
    }

    double num_(String key) {
      final v = json[key];
      if (v is num) return v.toDouble();
      throw FormatException('Campo numérico inválido "$key" en "$id".');
    }

    String str(String key) {
      final v = json[key];
      if (v is String && v.trim().isNotEmpty) return v.trim();
      throw FormatException('Campo de texto inválido "$key" en "$id".');
    }

    final lat = num_('lat');
    final lng = num_('lng');
    if (lat < -90 || lat > 90 || lng < -180 || lng > 180) {
      throw FormatException('Coordenadas fuera de rango en "$id".');
    }

    return TownModel(
      id: id,
      orden: (json['orden'] as num?)?.toInt() ?? 0,
      nombre: str('nombre'),
      provincia: str('provincia'),
      departamento: str('departamento'),
      lat: lat,
      lng: lng,
      msnm: (json['msnm'] as num?)?.toInt() ?? 0,
      kmRuta: num_('km_ruta'),
      tipo: TownType.parse(json['tipo'] as String?),
      etiqueta: (json['etiqueta'] as String?)?.trim() ?? '',
      enRutaPrincipal: json['en_ruta_principal'] as bool? ?? true,
      desvioKm: (json['desvio_km'] as num?)?.toDouble() ?? 0,
      wikipedia: (json['wikipedia'] as String?)?.trim(),
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'orden': orden,
        'nombre': nombre,
        'provincia': provincia,
        'departamento': departamento,
        'lat': lat,
        'lng': lng,
        'msnm': msnm,
        'km_ruta': kmRuta,
        'tipo': tipo.name,
        'etiqueta': etiqueta,
        'en_ruta_principal': enRutaPrincipal,
        'desvio_km': desvioKm,
        'wikipedia': wikipedia,
      };

  /// Nombre sin paréntesis: "Paracas (Cruce)" → "Paracas". Útil para búsquedas.
  String get nombreLugar =>
      nombre.replaceAll(RegExp(r'\s*\([^)]*\)'), '').trim();

  /// "Camaná, Arequipa"
  String get ubicacionCorta => '$nombre, $departamento';

  bool get esCruce => tipo == TownType.cruce || tipo == TownType.desvio;

  /// Parsea el contenido completo del asset (`{"localidades": [...]}`).
  static List<TownModel> listFromJsonString(String raw) {
    final decoded = jsonDecode(raw);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('El JSON de rutas debe ser un objeto.');
    }
    final list = decoded['localidades'];
    if (list is! List || list.isEmpty) {
      throw const FormatException('El JSON de rutas no contiene "localidades".');
    }
    final towns = <TownModel>[];
    final seen = <String>{};
    for (final item in list) {
      if (item is! Map<String, dynamic>) {
        throw const FormatException('Elemento de "localidades" inválido.');
      }
      final t = TownModel.fromJson(item);
      if (!seen.add(t.id)) {
        throw FormatException('ID de localidad duplicado: ${t.id}');
      }
      towns.add(t);
    }
    return towns;
  }

  @override
  bool operator ==(Object other) => other is TownModel && other.id == id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() => 'TownModel($id, km $kmRuta)';
}
