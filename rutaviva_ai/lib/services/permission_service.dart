import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart' as ph;

/// Foto del estado de permisos para la pantalla de Ajustes y el arranque del viaje.
class PermissionSnapshot {
  const PermissionSnapshot({
    required this.locationWhileInUse,
    required this.locationAlways,
    required this.notifications,
    required this.batteryOptimizationIgnored,
    required this.gpsEnabled,
  });

  /// Ubicación "Mientras se usa la app".
  final bool locationWhileInUse;

  /// Ubicación "Permitir todo el tiempo".
  final bool locationAlways;
  final bool notifications;

  /// `true` si la app está exenta de la optimización de batería.
  final bool batteryOptimizationIgnored;

  /// Interruptor de GPS del sistema.
  final bool gpsEnabled;

  /// Mínimo indispensable para arrancar el servicio.
  bool get canRunTrip => locationWhileInUse && notifications && gpsEnabled;

  /// Configuración ideal para viajes largos.
  bool get isOptimal => canRunTrip && locationAlways && batteryOptimizationIgnored;

  List<String> get missingForTrip => [
        if (!gpsEnabled) 'Activar el GPS del teléfono',
        if (!locationWhileInUse) 'Permiso de ubicación',
        if (!notifications) 'Permiso de notificaciones',
      ];
}

class PermissionService {
  PermissionService._();

  static Future<PermissionSnapshot> check() async {
    final results = await Future.wait<bool>([
      ph.Permission.locationWhenInUse.isGranted,
      ph.Permission.locationAlways.isGranted,
      ph.Permission.notification.isGranted,
      ph.Permission.ignoreBatteryOptimizations.isGranted,
      Geolocator.isLocationServiceEnabled(),
    ]);
    return PermissionSnapshot(
      locationWhileInUse: results[0],
      locationAlways: results[1],
      notifications: results[2],
      batteryOptimizationIgnored: results[3],
      gpsEnabled: results[4],
    );
  }

  static Future<bool> requestLocationWhileInUse() async {
    final status = await ph.Permission.locationWhenInUse.request();
    return status.isGranted;
  }

  /// Android 11+: primero "mientras se usa" y luego "todo el tiempo"
  /// (el sistema abre la pantalla de ajustes de la app para este último).
  static Future<bool> requestLocationAlways() async {
    if (!await ph.Permission.locationWhenInUse.isGranted) {
      final base = await ph.Permission.locationWhenInUse.request();
      if (!base.isGranted) return false;
    }
    final status = await ph.Permission.locationAlways.request();
    return status.isGranted;
  }

  static Future<bool> requestNotifications() async {
    final status = await ph.Permission.notification.request();
    return status.isGranted;
  }

  static Future<bool> requestIgnoreBatteryOptimizations() async {
    final status = await ph.Permission.ignoreBatteryOptimizations.request();
    return status.isGranted;
  }

  /// Pide en orden todo lo imprescindible. Devuelve el estado final.
  static Future<PermissionSnapshot> requestAllForTrip() async {
    await requestLocationWhileInUse();
    await requestNotifications();
    return check();
  }

  /// `true` si el usuario marcó "No volver a preguntar" para este permiso.
  static Future<bool> isLocationPermanentlyDenied() =>
      ph.Permission.locationWhenInUse.isPermanentlyDenied;

  static Future<bool> isNotificationPermanentlyDenied() =>
      ph.Permission.notification.isPermanentlyDenied;

  static Future<bool> openAppSettings() => ph.openAppSettings();

  static Future<bool> openLocationSettings() => Geolocator.openLocationSettings();
}
