# CS Mix

Reproductor y app de DJ de Catelotti Sport, para Android y Windows.

- **Reproductor**: cola con crossfade automático y transiciones manuales (Fade, Reverse, Brake, Corte) con punto de entrada por tema.
- **DJ en vivo**: dos decks, crossfader, pitch ±8 %, hot cues, sync de BPM y pre-escucha por auriculares con compensación de latencia del Bluetooth.
- **Biblioteca**: carpeta vigilada, BPM e intro analizados, importación y exportación de playlists `.m3u` de Virtual DJ.

## Descargar

Cada cambio en `main` genera un release en **Releases** con:

- `CS-Mix-x.y.z.apk` — instalar en el celular (permitir "instalar apps desconocidas").
- `CS-Mix-Windows-x.y.z.zip` — descomprimir y abrir `CSMix.exe`.

## Estructura

- `lib/` — app Flutter (pantallas, biblioteca, playlists de Virtual DJ, controladores).
- `packages/cs_audio/` — motor de audio en C++ ([miniaudio](https://miniaud.io)) expuesto por FFI.
- `android/app/cs-mix.jks` — clave de firma fija para que las actualizaciones se instalen encima. El repositorio es privado; no lo hagas público con esta clave.
