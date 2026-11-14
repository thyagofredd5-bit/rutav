import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:audio_service/audio_service.dart';
import 'package:http/http.dart' as http;

import '../core/app_constants.dart';

/// Notificación / cápsula de bloqueo del viaje (MediaSession nativo).
///
/// V4: sin botones musicales (solo un control discreto de sincronización GPS) y
/// con carátula SIEMPRE local: la imagen se descarga en Dart con User-Agent y se
/// pasa como `file://`, porque Android no envía User-Agent al bajar `artUri`
/// desde Wikimedia (caía en el ícono de nota musical).
/// Duración = km totales y posición = km recorridos (1 s = 1 km, `speed: 0.0`).
class TripMediaHandler extends BaseAudioHandler {
  Future<void> Function()? onRefreshRequested;
  Future<void> Function()? onPauseRequested;
  Future<void> Function()? onResumeRequested;
  Future<void> Function()? onStopRequested;
  Future<void> Function()? onExploreRequested;

  static const String _coverPrefix = 'rv_lock_cover_';
  static const String _darkName = 'rv_lock_cover_dark.png';

  final Map<String, String> _coverCache = <String, String>{};
  final Set<String> _downloading = <String>{};
  _Latest? _latest;
  Duration _lastPosition = Duration.zero;

  Future<void> publish({
    required String placeId,
    required String title,
    required String artist,
    required double kmTotal,
    required double kmTraveled,
    String? artUrl,
  }) async {
    final latest = _Latest(placeId, title, artist, kmTotal, kmTraveled, artUrl);
    _latest = latest;

    String? cover;
    if (artUrl != null && artUrl.isNotEmpty) cover = _coverCache[artUrl];
    cover ??= await _darkCover();
    await _emit(latest, cover);

    if (artUrl != null &&
        artUrl.isNotEmpty &&
        !_coverCache.containsKey(artUrl) &&
        _downloading.add(artUrl)) {
      final path = await _downloadCover(artUrl);
      _downloading.remove(artUrl);
      if (path != null) {
        _coverCache[artUrl] = path;
        final cur = _latest;
        // Si mientras tanto llegó otra lectura con la misma foto, se re-emite.
        if (cur != null && cur.artUrl == artUrl) await _emit(cur, path);
      }
    }
  }

  Future<void> _emit(_Latest l, String? coverPath) async {
    final durationSeconds = l.kmTotal.round().clamp(1, 9999).toInt();
    final pos = l.kmTraveled.round().clamp(0, durationSeconds).toInt();
    _lastPosition = Duration(seconds: pos);

    mediaItem.add(MediaItem(
      id: l.placeId,
      title: l.title,
      artist: l.artist,
      duration: Duration(seconds: durationSeconds),
      artUri: coverPath != null ? Uri.file(coverPath) : null,
      extras: {'km': l.kmTraveled, 'kmTotal': l.kmTotal},
    ));

    playbackState.add(PlaybackState(
      processingState: AudioProcessingState.ready,
      playing: true,
      controls: [
        MediaControl.custom(
          androidIcon: 'drawable/ic_stat_route',
          label: 'Actualizar ubicación',
          name: 'sync_gps',
        ),
      ],
      androidCompactActionIndices: const [0],
      systemActions: const <MediaAction>{},
      updatePosition: _lastPosition,
      bufferedPosition: _lastPosition,
      speed: 0.0,
      updateTime: DateTime.now(),
    ));
  }

  // ── Carátulas locales ──────────────────────────────────────────────────

  Future<String?> _downloadCover(String url) async {
    try {
      final dir = Directory.systemTemp;
      final file = File('${dir.path}/$_coverPrefix${url.hashCode.toUnsigned(32)}.jpg');
      if (await file.exists() && await file.length() > 2000) return file.path;
      final res = await http
          .get(Uri.parse(url), headers: AppConstants.httpHeaders)
          .timeout(const Duration(seconds: 12));
      if (res.statusCode != 200 || res.bodyBytes.length < 2000) return null;
      await for (final e in dir.list()) {
        if (e is File &&
            e.path.contains(_coverPrefix) &&
            !e.path.endsWith(_darkName) &&
            e.path != file.path) {
          try {
            await e.delete();
          } catch (_) {}
        }
      }
      await file.writeAsBytes(res.bodyBytes, flush: true);
      return file.path;
    } catch (_) {
      return null;
    }
  }

  /// PNG oscuro minimalista (degradado verde profundo → negro) generado en disco.
  Future<String?> _darkCover() async {
    try {
      final file = File('${Directory.systemTemp.path}/$_darkName');
      if (await file.exists() && await file.length() > 0) return file.path;
      const size = 600.0;
      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(recorder);
      final paint = ui.Paint()
        ..shader = ui.Gradient.linear(
          const ui.Offset(0, 0),
          const ui.Offset(size, size),
          const [ui.Color(0xFF0B3D2E), ui.Color(0xFF0B0D10)],
        );
      canvas.drawRect(const ui.Rect.fromLTWH(0, 0, size, size), paint);
      final image = await recorder.endRecording().toImage(600, 600);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      if (data == null) return null;
      await file.writeAsBytes(data.buffer.asUint8List(), flush: true);
      return file.path;
    } catch (_) {
      return null;
    }
  }

  /// Quita la notificación multimedia y libera el servicio en primer plano.
  Future<void> showStopped() async {
    _latest = null;
    playbackState.add(PlaybackState(
      processingState: AudioProcessingState.idle,
      playing: false,
    ));
    mediaItem.add(null);
  }

  Future<void> _call(Future<void> Function()? cb) async {
    if (cb == null) return;
    try {
      await cb();
    } catch (_) {}
  }

  @override
  Future<dynamic> customAction(String name, [Map<String, dynamic>? extras]) async {
    if (name == 'sync_gps') await _call(onRefreshRequested);
    return null;
  }

  @override
  Future<void> play() => _call(onResumeRequested);

  @override
  Future<void> pause() => _call(onPauseRequested);

  @override
  Future<void> stop() async {
    await _call(onStopRequested);
    await showStopped();
  }

  @override
  Future<void> skipToNext() => _call(onRefreshRequested);

  @override
  Future<void> skipToPrevious() => _call(onExploreRequested);

  /// La barra no es interactiva: se restaura la posición real.
  @override
  Future<void> seek(Duration position) async {
    playbackState
        .add(playbackState.value.copyWith(updatePosition: _lastPosition));
  }

  /// Cerrar la app desde recientes NO detiene el seguimiento.
  @override
  Future<void> onTaskRemoved() async {}

  @override
  Future<void> onNotificationDeleted() async {
    await _call(onStopRequested);
    await showStopped();
  }
}

class _Latest {
  _Latest(this.placeId, this.title, this.artist, this.kmTotal, this.kmTraveled,
      this.artUrl);
  final String placeId;
  final String title;
  final String artist;
  final double kmTotal;
  final double kmTraveled;
  final String? artUrl;
}

Future<TripMediaHandler> initTripMediaHandler() {
  return AudioService.init<TripMediaHandler>(
    builder: () => TripMediaHandler(),
    config: const AudioServiceConfig(
      androidNotificationChannelId: AppConstants.mediaChannelId,
      androidNotificationChannelName: AppConstants.mediaChannelName,
      androidNotificationIcon: 'drawable/ic_stat_route',
      androidShowNotificationBadge: false,
      androidNotificationOngoing: false,
      androidStopForegroundOnPause: false,
      androidResumeOnClick: true,
      androidNotificationClickStartsActivity: true,
      notificationColor: ui.Color(0xFF00E5A0),
      artDownscaleWidth: 1024,
      artDownscaleHeight: 1024,
    ),
  );
}
