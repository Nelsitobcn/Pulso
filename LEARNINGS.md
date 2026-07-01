# LEARNINGS.md — Pulso DJ

> Registro de bugs, errores y lecciones aprendidas durante el desarrollo.
> Leer ANTES de hacer cambios. Actualizar DESPUÉS de cada bug resuelto.

---

## Template

```
### [FECHA] — Título del bug
**Bug**: descripción del problema
**Causa**: por qué ocurrió
**Fix**: cómo se resolvió
**Regla**: qué hacer en el futuro para evitarlo
```

---

### [2026-07-01] — SYNC al beatgrid: el phase-lock se clavaba a medio beat por estado de tiempo mentiroso
**Bug**: al conectar el phase-lock al beatgrid real (fase desde `beatGrid.beats` en vez de contra t=0), el lazo NO convergía: el error de fase se quedaba clavado en 0.5 (medio beat) para siempre. En vivo = beatmatch que rebota y nunca engancha.
**Causa**: el timer del phase-lock cambia `slavePitch.rate` con el nudge (p.ej. 1.05), pero NO actualizaba `playTempo`/`playHostTime`/`pausedAt` del slave. Como `currentAudioTime(deck:)` estima la posición de archivo con `pausedAt + (now-playHostTime)*playTempo`, seguía integrando con el tempo BASE (1.0) mientras el audio real avanzaba al rate con nudge (1.05). → La posición de archivo que se usaba para consultar `gridPhase` estaba ATRASADA respecto al audio real → el lazo medía la fase sobre una posición mentirosa → feedback loop divergente que se satura a err=0.5.
**Fix**: cada tick, tras cambiar `pitch.rate`, re-anclar el estado de tiempo del slave: congelar la posición estimada actual (`sFile`, ya integrada honestamente hasta ahora) como `pausedAt`, `playHostTime = now`, `playTempo = newRate`. Igual en `stopPhaseLock` al restaurar el rate base. Verificado con simulación del lazo: sin fix se clava en 0.5, con fix converge a 0 en ~3.1s.
**Regla**: en un controlador de tiempo real, si cambias el rate EFECTIVO de un nodo de audio, cualquier estimador de posición que dependa de ese rate DEBE re-anclarse en el mismo instante. Un estimador de posición y el audio real son dos relojes; si uno cambia de velocidad y el otro no se entera, el lazo de control mide sobre una mentira. Cazado por review adversarial (Fugu) + simulación ejecutable del lazo — NO habría salido de "compila y el test feliz pasa".

### [2026-06-02/03] — SYNC: del align-once fallido al phase-lock continuo
**Bug**: al pulsar SYNC los kicks no coincidían (sonaba desfasado y derivaba). Costó MUCHAS iteraciones porque varios bugs se solapaban (ver abajo).
**Causa real (encadenada)**:
1. **El reloj de reproducción no avanzaba** (`currentAudioTime` siempre 0) — el completion callback de un `scheduleSegment` anterior, disparado por `player.stop()` al reprogramar, reseteaba `playHostTime=0` e `isPlaying=false` del segmento NUEVO. → arreglado con **token de generación de segmento** (ver entrada propia abajo).
2. **BPM impreciso** (128→127.5) por redondeo a 0.5 + resolución de lag entero. → arreglado con interpolación parabólica (entrada abajo).
3. **Un "align once" SIEMPRE deriva** (confirmado por investigación NotebookLM "Software DJ con IA 2026", 76 fuentes): imprecisiones de punto flotante + latencia. La solución pro es **phase-lock continuo (nudge)**, no un salto único.
4. **El seek de reposición saltaba al principio**: `target = cycle*beat + phaseTarget` con `cycle` derivado de `playerOutputTime` (tiempo del segmento, no posición absoluta) → mandaba el deck al inicio. → **se eliminó el seek por completo**; el SYNC NO reposiciona, respeta dónde suena el deck y solo ajusta tempo.
**Fix (estado actual)**: `sync()` iguala tempo (`newRate = masterBPM/slaveBPM`) y arranca `startPhaseLock()`: un `Timer` cada 100ms que mide el error de fase con la **posición real del player** (`playerTime(forNodeTime:)`, NO el tiempo estimado) y aplica un nudge proporcional al `pitch.rate` del slave (ganancia 2.0, cap ±25%). Verificado con réplica aislada + log a archivo de la app real: converge de ~150ms a 0ms y se mantiene.
**Regla**:
- Para medir fase entre players usa SIEMPRE `playerTime(forNodeTime: lastRenderTime)`, no estimaciones con `CACurrentMediaTime`.
- `AVAudioUnitTimePitch` NO es el culpable del desfase (medido: con/sin él, 2 players en el mismo `AVAudioTime` quedan a ~10ms). El problema era el código de sync, no el nodo.
- Un align-once nunca basta; usar phase-lock continuo.
**PENDIENTE (no resuelto, para Mauri / Fase 2)**:
- Si el usuario mueve el slider de tempo MANUALMENTE con el SYNC activo, su cambio pelea con el phase-lock (ambos escriben `pitch.rate`) → comportamiento errático. Debe: bloquear el slider mientras SYNC está activo, o desactivar SYNC al tocar el tempo manual.
- Asume beat-1 en t=0 (sin detección de downbeat real). Con música real (no las pistas de test) hará falta beatgrid con offset del primer beat.
- Investigación NBLM: SYNC de calidad pro suele requerir DSP de terceros (zplane élastique) en AVAudioUnit C++, no solo `AVAudioUnitTimePitch`.

### [2026-06-02] — currentAudioTime siempre 0: callback de segmento obsoleto reseteaba el reloj
**Bug**: tras dar play, `currentAudioTime` devolvía 0.00 constante; el SYNC calculaba fase sobre tiempo=0.
**Causa**: `player.stop()` (en load/seek/sync para reprogramar) dispara el completion callback `.dataPlayedBack` del segmento ANTERIOR. Ese callback (async, `Task @MainActor`) ponía `playHostTime=0`/`isPlaying=false`, pisando el segmento nuevo que startPlayback acababa de registrar.
**Fix**: token de generación por deck (`segmentTokenA/B`). Cada `scheduleSegment` lo incrementa; el callback solo actúa si su token sigue vigente. Un stop para reprogramar invalida el callback viejo.
**Regla**: con `AVAudioPlayerNode.scheduleSegment` + completion, SIEMPRE invalidar el callback al reprogramar (token/generación), o resetea estado del segmento nuevo.

### [2026-06-02] — BPM impreciso (128 → 127.5) por redondeo + resolución de lag
**Bug**: el análisis daba 127.5 a una pista de 128 BPM, causando drift en el SYNC.
**Causa**: `detectBPM` redondeaba a 0.5 (`(bpm*2).rounded()/2`) y la autocorrelación usaba lag entero (resolución ±1.5 BPM a tempos altos por `hopDuration=5.8ms`).
**Fix**: interpolación parabólica de 3 puntos alrededor del pico de autocorrelación → lag sub-muestra; se quitó el redondeo a 0.5 (ahora 1 decimal real).
**Regla**: para BPM preciso, refinar el pico de autocorrelación con interpolación parabólica; nunca redondear agresivo.

### [2026-06-02] — Volumen demasiado bajo: cadena de ganancia acumulada
**Bug**: el audio de la app se oía bajo.
**Causa**: cadena `masterVolume 0.8 × crossfader-centrado 0.707 × deck 1.0 = 0.566` (casi mitad). Medido: pico de salida −4 dBFS (la app NO es el culpable principal — sale a buen nivel).
**Fix parcial**: `masterVolume` por defecto subido 0.8 → 1.0.
**PENDIENTE**: Nelson reporta que incluso `afplay` (reproductor del sistema, SIN la app) suena extremadamente bajo en los Altavoces del Mac Studio → el problema de volumen es de SALIDA DE AUDIO DEL SISTEMA/hardware (altavoces Mac Studio dan poco nivel; la otra salida disponible es una webcam Brio 300). NO es de Pulso. Revisar config de audio del Mac / altavoces externos.

### [2026-06-02] — App SwiftPM no abre ventana / drag no funciona sin firma
**Bug**: `swift run Pulso` arranca el proceso pero macOS lo trata como "background only" (sin ventana); y el drag&drop / clics no responden.
**Causa**: un ejecutable plano de SwiftPM no es un `.app` bundle firmado con sandbox → sin ventana con foco, sin permisos de interacción/archivos.
**Fix**: compilar y correr desde el `.xcodeproj` existente (target `Pulso (macOS)`, firma "Sign to Run Locally"). El `.app` firmado SÍ recibe drag, clics y acceso a archivos.
**Regla**: para PROBAR Pulso de verdad (interacción), usar `xcodebuild -scheme "Pulso (macOS)" ... && open <.app>`, NUNCA `swift run`. `swift build` solo sirve para verificar que COMPILA. La ventana puede abrir fuera de pantalla (Nelson tiene 2 monitores) → reposicionar con AppleScript a (100,80).

### [2026-06-02] — Drag biblioteca→deck re-importaba la pista (duplicado)
**Bug**: arrastrar una fila de la biblioteca a un deck creaba un duplicado en la biblioteca y re-analizaba BPM (lento), en vez de cargar la pista ya analizada.
**Causa**: `handleDrop` recibía solo la URL y siempre llamaba `importTracks(urls:)`, sin comprobar si esa URL ya estaba en `libraryService.tracks`.
**Fix**: en `handleDrop` se busca primero `libraryService.tracks.first(where: { $0.url == url })` y se reutiliza esa pista; solo se importa si no existe (caso: arrastre desde Finder).
**Regla**: al recibir un drop con una URL, comprobar SIEMPRE si el recurso ya existe en el modelo antes de importarlo. Importar es la última opción, no la primera.

### [2026-06-02] — Botón TEST "T" de debugging quedó en la UI
**Bug**: botón rojo "T" (acelera 2s y vuelve) visible en los controles de transporte; era solo para verificar TimePitch durante desarrollo.
**Fix**: eliminado el botón en `TransportControlsView` y el método `testSetRate(_:deck:)` en `AudioEngine` (verificado con grep que no quedaban referencias).
**Regla**: marcar el código de debugging con `// TEST` o `#if DEBUG` desde el inicio para poder localizarlo y quitarlo antes de release.

### [2026-06-24] — App GUI no encuentra yt-dlp/ffmpeg/deno (PATH minimal)
**Bug**: el buscador de YouTube "no bajaba nada" desde la app, aunque el comando yt-dlp funcionaba en terminal. Fallo silencioso.
**Causa raíz**: una app macOS lanzada por Finder/`open` hereda un PATH minimal (`/usr/bin:/bin`), SIN `/opt/homebrew/bin`. yt-dlp llama a `ffmpeg` (extraer audio) y `deno` (resolver retos JS de YouTube) por nombre → no los encuentra → falla.
**Cómo se diagnosticó**: reproducir el comando con `env -i PATH=/usr/bin:/bin yt-dlp ...` → mismo error que en la app. Confirmó que era el PATH, no yt-dlp.
**Fix**: en `YouTubeService.run()` inyectar `process.environment["PATH"]` con `/opt/homebrew/bin` delante + pasar `--ffmpeg-location /opt/homebrew/bin` a yt-dlp.
**Regla**: cualquier `Process` que invoque un binario de Homebrew desde una app GUI DEBE inyectar el PATH en `process.environment` y/o pasar rutas absolutas. Nunca asumir que la app hereda el PATH del shell.
**Files**: `Pulso/Services/Library/YouTubeService.swift`

### [2026-06-24] — Verificar UI sin poder clicar: auto-test gated por env var
**Aprendizaje**: automatizar clics en la app (cliclick/AppleScript por coordenadas) es frágil y falla a menudo. Para verificar un flujo de UI de verdad sin clicar, usar un hook de auto-test bajo `#if DEBUG` disparado por variable de entorno (ej. `PULSO_YT_TEST=1`) que ejercita el código real (descarga→análisis→deck→play) y deja evidencia (NSLog + archivos + estado observable por captura).
**Files**: `Pulso/App/PulsoApp.swift`

### [2026-07-01] — `vDSP_conv` para autocorrelación desbordaba el buffer de salida
**Bug**: en `BeatGridAnalyzer.estimateBeatPeriod`, la autocorrelación se hacía con `vDSP_conv(env, env, &autocorr, resultLen=count, filterLen=count)` sobre un buffer `autocorr` de tamaño `count`. Una convolución "full" de dos señales de longitud N produce `2N-1` muestras → vDSP escribía fuera de los límites del array = corrupción de memoria silenciosa (el test pasaba por suerte, el BPM salía bien).
**Cómo se diagnosticó**: lo cazó el Verifier adversarial Fugu (`~/bin/fugu_seal.sh`) al sellar el diff; insistió dos rondas hasta reescribirlo.
**Fix**: eliminado `vDSP_conv`. Autocorrelación calculada lag-a-lag con `vDSP_dotpr` en un bucle `for lag in 0...maxLag` → `autocorr[lag] = Σ env[n]·env[n+lag]`. Solo computa los lags del rango plausible (50–210 BPM) y se indexa exactamente en `[0, maxLag]` → imposible desbordar, y más barato (no calcula lags que no se usan).
**Regla**: `vDSP_conv`/`vDSP_corr` producen `resultLen` muestras pero LEEN hasta `resultLen + filterLen - 1` del primer operando; el buffer de salida y el padding del input deben dimensionarse para eso. Si solo necesitas unos pocos lags de una autocorrelación, `vDSP_dotpr` por lag es más seguro y a menudo más rápido que una convolución full.
**Files**: `Pulso/Services/Audio/BeatGridAnalyzer.swift`
