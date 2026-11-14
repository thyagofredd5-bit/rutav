package com.rutaviva.ai

import com.ryanheise.audioservice.AudioServiceActivity

/// Hereda el FlutterEngine compartido de audio_service: el isolate principal
/// (GPS + MediaSession) sigue vivo aunque cierres la interfaz.
class MainActivity : AudioServiceActivity()
