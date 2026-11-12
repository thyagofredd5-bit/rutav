import 'dart:convert';
import 'dart:math' as math;

import '../core/app_constants.dart';

/// Qué disparó una lectura de ubicación.
enum UpdateReason {
  start('Inicio de ruta'),
  timer('Temporizador'),
  signalRegained('Señal recuperada'),
  manual('Actualización manual');

  const UpdateReason(this.label);
  final String label;

  static UpdateReason parse(String? raw) => UpdateReason.values.firstWhere(
        (e) => e.name == raw,
        orElse: () => UpdateReason.manual,
      );
}

/// Configuración del viaje activo (se comparte con el isolate del servicio).
class TripConfig {
  const TripConfig({
    required this.originId,
    required this.destinationId,
    this.intervalMinutes = AppConstants.defaultIntervalMinutes,
    this.updateOnSignalReturn = true,
    this.detectionRadiusKm = AppConstants.defaultDetectionRadiusKm,
    this.keepCpuAwake = false,
  });

  static const TripConfig limaToArequipa =
      TripConfig(originId: 'lima-centro', destinationId: 'arequipa');
  static const TripConfig arequipaToLima =
      TripConfig(originId: 'arequipa', destinationId: 'lima-centro');

  final String originId;
  final String destinationId;
  final int intervalMinutes;

  /// Disparador por retorno de señal móvil (ConnectivityListener).
  final bool updateOnSignalReturn;

  /// Radio para considerar que estás "en" un pueblo.
  final double detectionRadiusKm;

  /// Mantiene la CPU despierta (wake lock): más preciso pero gasta más batería.
  final bool keepCpuAwake;

  bool get isValid =>
      originId.isNotEmpty &&
      destinationId.isNotEmpty &&
      originId != destinationId &&
      intervalMinutes >= 5;

  TripConfig reversed() =>
      copyWith(originId: destinationId, destinationId: originId);

  TripConfig copyWith({
    String? originId,
    String? destinationId,
    int? intervalMinutes,
    bool? updateOnSignalReturn,
    double? detectionRadiusKm,
    bool? keepCpuAwake,
  }) =>
      TripConfig(
        originId: originId ?? this.originId,
        destinationId: destinationId ?? this.destinationId,
        intervalMinutes: intervalMinutes ?? this.intervalMinutes,
        updateOnSignalReturn: updateOnSignalReturn ?? this.updateOnSignalReturn,
        detectionRadiusKm: detectionRadiusKm ?? this.detectionRadiusKm,
        keepCpuAwake: keepCpuAwake ?? this.keepCpuAwake,
      );

  Map<String, dynamic> toJson() => {
        'originId': originId,
        'destinationId': destinationId,
        'intervalMinutes': intervalMinutes,
        'updateOnSignalReturn': updateOnSignalReturn,
        'detectionRadiusKm': detectionRadiusKm,
        'keepCpuAwake': keepCpuAwake,
      };

  factory TripConfig.fromJson(Map<String, dynamic> json) => TripConfig(
        originId: json['originId'] as String? ?? 'lima-centro',
        destinationId: json['destinationId'] as String? ?? 'arequipa',
        intervalMinutes: (json['intervalMinutes'] as num?)?.toInt() ??
            AppConstants.defaultIntervalMinutes,
        updateOnSignalReturn: json['updateOnSignalReturn'] as bool? ?? true,
        detectionRadiusKm: (json['detectionRadiusKm'] as num?)?.toDouble() ??
            AppConstants.defaultDetectionRadiusKm,
        keepCpuAwake: json['keepCpuAwake'] as bool? ?? false,
      );

  String encode() => jsonEncode(toJson());

  static TripConfig decode(String raw) =>
      TripConfig.fromJson(jsonDecode(raw) as Map<String, dynamic>);
}

/// Resultado puro del análisis geoespacial offline de una coordenada.
class TripProgress {
  const TripProgress({
    required this.latitude,
    required this.longitude,
    required this.originName,
    required this.destinationName,
    required this.currentTownId,
    required this.currentTownName,
    required this.currentDepartment,
    required this.atTown,
    required this.distanceToCurrentTownKm,
    required this.progress,
    required this.kmTraveled,
    required this.kmTotal,
    required this.routeKm,
    required this.offRouteKm,
    required this.arrived,
    required this.direction,
    required this.computeMicros,
    this.nextTownId,
    this.nextTownName,
    this.nextTownDistanceKm,
  });

  final double latitude;
  final double longitude;
  final String originName;
  final String destinationName;

  /// `puebloActual`: pueblo dentro del radio, o último pueblo superado.
  final String currentTownId;
  final String currentTownName;
  final String currentDepartment;

  /// `true` si estás dentro del radio de detección del pueblo actual.
  final bool atTown;
  final double distanceToCurrentTownKm;

  /// `siguientePueblo` y distancia aproximada por carretera.
  final String? nextTownId;
  final String? nextTownName;
  final double? nextTownDistanceKm;

  /// 0.0 – 1.0
  final double progress;
  final double kmTraveled;
  final double kmTotal;

  /// Posición proyectada sobre la carretera (km desde Lima).
  final double routeKm;

  /// Distancia perpendicular a la carretera (si es grande, estás fuera de ruta).
  final double offRouteKm;
  final bool arrived;

  /// +1 = sentido Lima→Arequipa (km crecientes), -1 = inverso.
  final int direction;
  final int computeMicros;

  int get percent => (progress * 100).round().clamp(0, 100);
  double get kmRemaining => math.max(0.0, kmTotal - kmTraveled);
  bool get isOffRoute => offRouteKm > 25;

  Map<String, dynamic> toJson() => {
        'lat': latitude,
        'lng': longitude,
        'originName': originName,
        'destinationName': destinationName,
        'currentTownId': currentTownId,
        'currentTownName': currentTownName,
        'currentDepartment': currentDepartment,
        'atTown': atTown,
        'distanceToCurrentTownKm': distanceToCurrentTownKm,
        'nextTownId': nextTownId,
        'nextTownName': nextTownName,
        'nextTownDistanceKm': nextTownDistanceKm,
        'progress': progress,
        'kmTraveled': kmTraveled,
        'kmTotal': kmTotal,
        'routeKm': routeKm,
        'offRouteKm': offRouteKm,
        'arrived': arrived,
        'direction': direction,
        'computeMicros': computeMicros,
      };

  factory TripProgress.fromJson(Map<String, dynamic> j) => TripProgress(
        latitude: (j['lat'] as num).toDouble(),
        longitude: (j['lng'] as num).toDouble(),
        originName: j['originName'] as String? ?? '',
        destinationName: j['destinationName'] as String? ?? '',
        currentTownId: j['currentTownId'] as String? ?? '',
        currentTownName: j['currentTownName'] as String? ?? '',
        currentDepartment: j['currentDepartment'] as String? ?? '',
        atTown: j['atTown'] as bool? ?? false,
        distanceToCurrentTownKm:
            (j['distanceToCurrentTownKm'] as num?)?.toDouble() ?? 0,
        nextTownId: j['nextTownId'] as String?,
        nextTownName: j['nextTownName'] as String?,
        nextTownDistanceKm: (j['nextTownDistanceKm'] as num?)?.toDouble(),
        progress: (j['progress'] as num?)?.toDouble() ?? 0,
        kmTraveled: (j['kmTraveled'] as num?)?.toDouble() ?? 0,
        kmTotal: (j['kmTotal'] as num?)?.toDouble() ?? 0,
        routeKm: (j['routeKm'] as num?)?.toDouble() ?? 0,
        offRouteKm: (j['offRouteKm'] as num?)?.toDouble() ?? 0,
        arrived: j['arrived'] as bool? ?? false,
        direction: (j['direction'] as num?)?.toInt() ?? 1,
        computeMicros: (j['computeMicros'] as num?)?.toInt() ?? 0,
      );
}

/// Lectura completa: análisis + metadatos de la lectura GPS.
class TripSnapshot {
  const TripSnapshot({
    required this.progress,
    required this.readAt,
    required this.reason,
    this.accuracyMeters,
    this.isStale = false,
  });

  final TripProgress progress;
  final DateTime readAt;
  final UpdateReason reason;
  final double? accuracyMeters;

  /// `true` si se usó la última posición conocida (el GPS no respondió a tiempo).
  final bool isStale;

  Map<String, dynamic> toJson() => {
        'progress': progress.toJson(),
        'readAt': readAt.toIso8601String(),
        'reason': reason.name,
        'accuracyMeters': accuracyMeters,
        'isStale': isStale,
      };

  factory TripSnapshot.fromJson(Map<String, dynamic> j) => TripSnapshot(
        progress: TripProgress.fromJson(j['progress'] as Map<String, dynamic>),
        readAt: DateTime.tryParse(j['readAt'] as String? ?? '') ?? DateTime.now(),
        reason: UpdateReason.parse(j['reason'] as String?),
        accuracyMeters: (j['accuracyMeters'] as num?)?.toDouble(),
        isStale: j['isStale'] as bool? ?? false,
      );

  String encode() => jsonEncode(toJson());

  static TripSnapshot? tryDecode(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      return TripSnapshot.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }
}
