import 'dart:async';
import 'dart:ui' show Color;

import 'package:audio_service/audio_service.dart';

import '../core/app_constants.dart';

/// Reproductor multimedia del viaje (MediaSession nativo de Android / One UI).
/// Vive en el isolate principal. Es el ÚNICO servicio en primer plano.
///
/// Truco: duración = km totales (1 s = 1 km) y posición = km recorridos; con
/// `speed: 0.0` la barra no avanza sola, solo cuando llega una lectura GPS.
class TripMediaHandler extends BaseAudioHandler {
  Future<void> Function()? onRefreshRequested;
  Future<void> Function()? onPauseRequested;
  Future<void> Function()? onResumeRequested;
  Future<void> Function()? onStopRequested;
  Future<void> Function()? onExploreRequested;

  Duration _lastPosition = Duration.zero;
  int _durationSeconds = 1;

  Future<void> publish({
    required String placeId,
    required String title,
    required String artist,
    required double kmTotal,
    required double kmTraveled,
    String? artUrl,
    bool paused = false,
  }) async {
    _durationSeconds = kmTotal.round().clamp(1, 9999).toInt();
    final pos = kmTraveled.round().clamp(0, _durationSeconds).toInt();

    Uri? uri;
    if (artUrl != null && artUrl.isNotEmpty) {
      final parsed = Uri.tryParse(artUrl);
      if (parsed != null && (parsed.scheme == 'http' || parsed.scheme == 'https')) {
        uri = parsed;
      }
    }

    mediaItem.add(MediaItem(
      id: placeId,
      title: title,
      artist: artist,
      duration: Duration(seconds: _durationSeconds),
      artUri: uri,
      artHeaders: uri != null ? {'User-Agent': AppConstants.httpUserAgent} : null,
      extras: {'km': kmTraveled, 'kmTotal': kmTotal},
    ));

    _lastPosition = Duration(seconds: pos);
    playbackState.add(PlaybackState(
      processingState: AudioProcessingState.ready,
      playing: !paused,
      controls: [
        MediaControl.skipToPrevious,
        paused ? MediaControl.play : MediaControl.pause,
        MediaControl.skipToNext,
      ],
      androidCompactActionIndices: const [0, 1, 2],
      systemActions: const {
        MediaAction.seek,
        MediaAction.play,
        MediaAction.pause,
        MediaAction.stop,
        MediaAction.skipToNext,
        MediaAction.skipToPrevious,
      },
      updatePosition: _lastPosition,
      bufferedPosition: _lastPosition,
      speed: 0.0,
      updateTime: DateTime.now(),
    ));
  }

  /// Quita la notificación multimedia y libera el servicio en primer plano.
  Future<void> showStopped() async {
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

  /// El usuario no puede mover la barra: se restaura la posición real.
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
      notificationColor: Color(0xFF00E5A0),
      artDownscaleWidth: 1024,
      artDownscaleHeight: 1024,
    ),
  );
}
