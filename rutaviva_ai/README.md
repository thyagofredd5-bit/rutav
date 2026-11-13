# RutaViva AI

Copiloto de viaje por carretera para la ruta **Lima ⇄ Arequipa** (Panamericana Sur).
Funciona con cobertura intermitente: el cálculo de pueblo actual y progreso es 100 % offline
(Haversine + proyección sobre la carretera) y la ficha turística de cada pueblo se genera
bajo demanda con Gemini (con Google Search) y se guarda en caché local.

## Funciones
- Notificación fija y silenciosa con barra de progreso (pueblo actual, % y próxima parada).
- Lectura de ubicación cada 15/30/60 min y al recuperar señal 4G/5G.
- Línea de tiempo de 31 localidades; al tocar una se abre fotos + historia, clima, gastronomía y paradas.
- Tema oscuro AMOLED.

## Compilar con GitHub Actions (recomendado)
1. Sube este proyecto a un repositorio de GitHub.
2. En **Actions → Build APK → Run workflow** (o haz un push a `main`).
3. Descarga `rutaviva-ai-apk` (contiene `app-release.apk`) desde los *Artifacts*.

## Compilar en local
Requisitos: Flutter estable y Java 21.

```bash
flutter create --platforms=android --org com.rutaviva --project-name ai /tmp/scaffold
rm -f /tmp/scaffold/android/app/build.gradle.kts
rsync -a --ignore-existing /tmp/scaffold/android/ android/
flutter pub get
flutter build apk --release
```
El APK queda en `build/app/outputs/flutter-apk/app-release.apk`.

## Primer uso
1. Abre **Ajustes** y pega tu API Key de Gemini (Google AI Studio). La de Google Places es opcional.
2. Concede los permisos (Ubicación "Todo el tiempo", Notificaciones, ignorar optimización de batería).
3. Elige sentido e intervalo y pulsa **Iniciar**.

> El `applicationId` / namespace es `com.rutaviva.ai`. Cambia el correo del `User-Agent`
> en `lib/core/app_constants.dart` por el tuyo (Wikimedia lo exige).

## V2
- Tarjeta Now Playing con foto real del pueblo, notificación multimedia con foto y progreso en km.
- Fotos filtradas (Places → Wikipedia geosearch → Commons anti-basura → respaldo por zona).
- Gemini con cascada automática de modelos (404/400) y reintento sin `google_search`.

## Novedades V3

- **Una sola notificación**: reproductor multimedia nativo (`audio_service`, `MediaSession`,
  servicio `mediaPlayback|location`). Título `📍 Lugar (msnm)`, artista con destino/próximo pueblo,
  foto del lugar como carátula y barra de progreso en kilómetros (1 s = 1 km, `speed: 0.0`).
  Botones: ⏮ explorar el lugar actual · ⏸/▶ pausar o reanudar lecturas · ⏭ lectura GPS inmediata.
- **Tres modos**: corredor Lima–Arequipa (offline), viaje a cualquier destino del Perú
  (Nominatim + OSRM) y explorador libre «¿Dónde estoy?».
- **Carga rápida**: fotos de Wikipedia es/en + Commons en paralelo (timeout 2.5 s), Gemini con JSON
  directo (sin `google_search` por defecto), precarga en segundo plano del pueblo actual y el siguiente.
- Requiere Flutter ≥ 3.27 (`audio_service` 0.18.18).
- Nominatim y el servidor demo de OSRM son de uso justo: no los uses para tráfico masivo.
