import 'dart:math' as math;

import 'package:flutter/services.dart' show AssetBundle, rootBundle;

import '../core/app_constants.dart';
import '../models/town_model.dart';
import '../models/trip_models.dart';

/// Estado de una localidad respecto a tu posición en el viaje.
enum TownStatus { passed, current, upcoming, detour }

/// Fila de la línea de tiempo de la ruta.
class RouteStop {
  const RouteStop({
    required this.town,
    required this.status,
    required this.kmFromOrigin,
    required this.kmToDestination,
  });

  final TownModel town;
  final TownStatus status;
  final double kmFromOrigin;
  final double kmToDestination;
}

class TownDistance {
  const TownDistance(this.town, this.km);
  final TownModel town;
  final double km;
}

class _Projection {
  const _Projection(this.routeKm, this.offRouteKm);
  final double routeKm;
  final double offRouteKm;
}

/// Motor 100 % offline: no usa red, solo matemáticas sobre el JSON embebido.
class OfflineGeocoderService {
  OfflineGeocoderService._(this.towns)
      : _main = towns.where((t) => t.enRutaPrincipal).toList(growable: false),
        _byId = {for (final t in towns) t.id: t};

  /// Todas las localidades ordenadas por km ascendente (Lima → Arequipa).
  final List<TownModel> towns;
  final List<TownModel> _main;
  final Map<String, TownModel> _byId;

  static const double _earthRadiusKm = 6371.0088;
  static const double _eps = 0.01;

  // ── Construcción ───────────────────────────────────────────────────────

  static Future<OfflineGeocoderService> loadFromAssets({
    AssetBundle? bundle,
    String assetPath = AppConstants.routeAsset,
  }) async {
    final raw = await (bundle ?? rootBundle).loadString(assetPath);
    return OfflineGeocoderService.fromTowns(TownModel.listFromJsonString(raw));
  }

  factory OfflineGeocoderService.fromTowns(List<TownModel> all) {
    final main = all.where((t) => t.enRutaPrincipal).length;
    if (all.length < 2 || main < 2) {
      throw ArgumentError('Se necesitan al menos 2 localidades en la ruta principal.');
    }
    final sorted = [...all]..sort((a, b) {
        final c = a.kmRuta.compareTo(b.kmRuta);
        return c != 0 ? c : a.orden.compareTo(b.orden);
      });
    return OfflineGeocoderService._(List<TownModel>.unmodifiable(sorted));
  }

  // ── Consultas simples ──────────────────────────────────────────────────

  TownModel? byId(String id) => _byId[id];

  TownModel requireById(String id) {
    final t = _byId[id];
    if (t == null) throw StateError('Localidad desconocida: $id');
    return t;
  }

  /// Localidades que pueden elegirse como origen/destino (sin desvíos).
  List<TownModel> get selectableTowns => _main;

  // ── Haversine ──────────────────────────────────────────────────────────

  /// Distancia ortodrómica (km) entre dos coordenadas.
  static double haversineKm(
      double lat1, double lon1, double lat2, double lon2) {
    final dLat = _rad(lat2 - lat1);
    final dLon = _rad(lon2 - lon1);
    final sinLat = math.sin(dLat / 2);
    final sinLon = math.sin(dLon / 2);
    final a = sinLat * sinLat +
        math.cos(_rad(lat1)) * math.cos(_rad(lat2)) * sinLon * sinLon;
    return 2 * _earthRadiusKm * math.asin(math.min(1.0, math.sqrt(a)));
  }

  static double _rad(double deg) => deg * math.pi / 180.0;

  /// Distancia a TODAS las localidades, ordenada de menor a mayor.
  List<TownDistance> distancesFrom(double lat, double lng) {
    final out = <TownDistance>[
      for (final t in towns)
        TownDistance(t, haversineKm(lat, lng, t.lat, t.lng)),
    ]..sort((a, b) => a.km.compareTo(b.km));
    return out;
  }

  /// Mide cuántos microsegundos tarda `distancesFrom` (diagnóstico < 5 ms).
  int benchmarkMicros(double lat, double lng, {int iterations = 200}) {
    final sw = Stopwatch()..start();
    for (var i = 0; i < iterations; i++) {
      distancesFrom(lat, lng);
    }
    sw.stop();
    return sw.elapsedMicroseconds ~/ iterations;
  }

  // ── Análisis principal ─────────────────────────────────────────────────

  TripProgress analyze({
    required double latitude,
    required double longitude,
    required TripConfig config,
  }) {
    final sw = Stopwatch()..start();

    final origin = requireById(config.originId);
    final dest = requireById(config.destinationId);
    final kmO = origin.kmRuta;
    final kmD = dest.kmRuta;
    final dir = kmD >= kmO ? 1 : -1;
    final total = (kmD - kmO).abs();
    final lo = math.min(kmO, kmD);
    final hi = math.max(kmO, kmD);

    // 1) Proyección sobre la carretera y porcentaje de progreso.
    final proj = _projectOnRoute(latitude, longitude);
    final progress = total <= 0
        ? 0.0
        : math.max(0.0, math.min(1.0, (proj.routeKm - kmO) / (kmD - kmO)));
    final kmTraveled = progress * total;

    // 2) Pueblo más cercano (Haversine) dentro del tramo del viaje.
    TownModel? nearest;
    var nearestKm = double.infinity;
    for (final t in towns) {
      if (!_inRange(t, lo, hi)) continue;
      final d = haversineKm(latitude, longitude, t.lat, t.lng);
      if (d < nearestKm) {
        nearestKm = d;
        nearest = t;
      }
    }

    // 3) puebloActual: dentro del radio, o último pueblo superado.
    final TownModel current;
    final bool atTown;
    if (nearest != null && nearestKm <= config.detectionRadiusKm) {
      current = nearest;
      atTown = true;
    } else {
      current = _lastPassed(proj.routeKm, dir, lo, hi) ?? origin;
      atTown = false;
    }
    final distToCurrent = atTown
        ? nearestKm
        : haversineKm(latitude, longitude, current.lat, current.lng);

    // 4) siguientePueblo en el sentido del viaje (solo ruta principal).
    final next = _nextAfter(current.kmRuta, dir, lo, hi);
    double? nextDist;
    if (next != null) {
      if (proj.offRouteKm > 25) {
        nextDist = haversineKm(latitude, longitude, next.lat, next.lng);
      } else {
        nextDist = math.max(0.0, (next.kmRuta - proj.routeKm) * dir);
      }
    }

    // 5) ¿Llegaste?
    final distToDest = haversineKm(latitude, longitude, dest.lat, dest.lng);
    final arrived = total > 0 && (progress >= 0.99 || distToDest <= 3.0);

    sw.stop();
    return TripProgress(
      latitude: latitude,
      longitude: longitude,
      originName: origin.nombreLugar,
      destinationName: dest.nombreLugar,
      currentTownId: current.id,
      currentTownName: current.nombre,
      currentDepartment: current.departamento,
      atTown: atTown,
      distanceToCurrentTownKm: distToCurrent,
      nextTownId: next?.id,
      nextTownName: next?.nombre,
      nextTownDistanceKm: nextDist,
      progress: progress,
      kmTraveled: kmTraveled,
      kmTotal: total,
      routeKm: proj.routeKm,
      offRouteKm: proj.offRouteKm,
      arrived: arrived,
      direction: dir,
      computeMicros: sw.elapsedMicroseconds,
    );
  }

  // ── Línea de tiempo ────────────────────────────────────────────────────

  /// Lista de paradas del viaje (en orden de recorrido) con su estado.
  List<RouteStop> buildTimeline(TripConfig config, {TripProgress? progress}) {
    final origin = requireById(config.originId);
    final dest = requireById(config.destinationId);
    final dir = dest.kmRuta >= origin.kmRuta ? 1 : -1;
    final lo = math.min(origin.kmRuta, dest.kmRuta);
    final hi = math.max(origin.kmRuta, dest.kmRuta);

    final stops = towns.where((t) => _inRange(t, lo, hi)).toList();
    if (dir < 0) {
      final reversed = stops.reversed.toList();
      stops
        ..clear()
        ..addAll(reversed);
    }

    final current = progress != null ? _byId[progress.currentTownId] : origin;
    final double pivot;
    if (current == null) {
      pivot = origin.kmRuta;
    } else if (current.enRutaPrincipal) {
      pivot = current.kmRuta;
    } else {
      pivot = progress?.routeKm ?? current.kmRuta;
    }

    return [
      for (final t in stops)
        RouteStop(
          town: t,
          status: t.id == current?.id
              ? TownStatus.current
              : !t.enRutaPrincipal
                  ? TownStatus.detour
                  : (dir > 0 ? t.kmRuta < pivot : t.kmRuta > pivot)
                      ? TownStatus.passed
                      : TownStatus.upcoming,
          kmFromOrigin: (t.kmRuta - origin.kmRuta).abs(),
          kmToDestination: (dest.kmRuta - t.kmRuta).abs(),
        ),
    ];
  }

  // ── Internos ───────────────────────────────────────────────────────────

  bool _inRange(TownModel t, double lo, double hi) =>
      t.kmRuta >= lo - _eps && t.kmRuta <= hi + _eps;

  /// Último pueblo de la ruta principal ya superado en el sentido del viaje.
  TownModel? _lastPassed(double routeKm, int dir, double lo, double hi) {
    TownModel? best;
    for (final t in _main) {
      if (!_inRange(t, lo, hi)) continue;
      if (dir > 0) {
        if (t.kmRuta <= routeKm + _eps && (best == null || t.kmRuta > best.kmRuta)) {
          best = t;
        }
      } else {
        if (t.kmRuta >= routeKm - _eps && (best == null || t.kmRuta < best.kmRuta)) {
          best = t;
        }
      }
    }
    return best;
  }

  /// Primer pueblo de la ruta principal estrictamente después de [refKm].
  TownModel? _nextAfter(double refKm, int dir, double lo, double hi) {
    TownModel? best;
    for (final t in _main) {
      if (!_inRange(t, lo, hi)) continue;
      if (dir > 0) {
        if (t.kmRuta > refKm + _eps && (best == null || t.kmRuta < best.kmRuta)) {
          best = t;
        }
      } else {
        if (t.kmRuta < refKm - _eps && (best == null || t.kmRuta > best.kmRuta)) {
          best = t;
        }
      }
    }
    return best;
  }

  /// Proyecta (lat, lng) sobre la polilínea de la ruta principal.
  /// Usa plano local equirectangular (error despreciable a escala de 100 km).
  _Projection _projectOnRoute(double lat, double lng) {
    var bestDist = double.infinity;
    var bestKm = _main.first.kmRuta;

    for (var i = 0; i < _main.length - 1; i++) {
      final a = _main[i];
      final b = _main[i + 1];
      final cosLat = math.cos(_rad(a.lat));
      final bx = (b.lng - a.lng) * 111.320 * cosLat;
      final by = (b.lat - a.lat) * 110.574;
      final px = (lng - a.lng) * 111.320 * cosLat;
      final py = (lat - a.lat) * 110.574;
      final len2 = bx * bx + by * by;
      final t = len2 == 0
          ? 0.0
          : math.max(0.0, math.min(1.0, (px * bx + py * by) / len2));
      final dx = px - t * bx;
      final dy = py - t * by;
      final dist = math.sqrt(dx * dx + dy * dy);
      if (dist < bestDist) {
        bestDist = dist;
        bestKm = a.kmRuta + t * (b.kmRuta - a.kmRuta);
      }
    }
    return _Projection(bestKm, bestDist);
  }
}
