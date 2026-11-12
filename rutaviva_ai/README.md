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
Requisitos: Flutter estable y Java 17.

```bash
flutter create --project-name rutaviva_ai --org com.rutaviva --platforms=android /tmp/scaffold
rsync -a --ignore-existing /tmp/scaffold/android/ android/
rm -f android/app/build.gradle.kts
rm -rf android/app/src/main/kotlin/com/rutaviva/rutaviva_ai
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
