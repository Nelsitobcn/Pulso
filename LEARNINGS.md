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

### [2026-06-02] — SYNC igualaba tempo pero no alineaba la fase de los beats
**Bug**: al pulsar SYNC, el deck slave adoptaba el BPM del master pero los kicks no coincidían — sonaba "doblado". El rate era correcto, la fase no.
**Causa**: `sync(slave:)` solo ajustaba `pitch.rate` (BPM master/slave). No reposicionaba el slave, así que el beat 1 de cada track caía en momentos distintos. Además `scheduleSegment(at: nil)` arrancaba el player en el siguiente ciclo de render sin coordinación con el master.
**Fix**: si ambos decks reproducen, se calcula la fase del master (`tiempo % beatDur`), se reposiciona el slave al múltiplo de su beatDur que iguale esa fase, y se programa el arranque con `AVAudioTime(hostTime:)` a un hostTime futuro común (~50ms) para que entre en el mismo ciclo de render. La base de tiempo (`pausedAt`/`playHostTime`) se registra con `AVAudioTime.seconds(forHostTime:)` reflejando el arranque futuro desde `targetSlaveTime`, no el tiempo viejo arrancando ahora (si no, el playhead se descuadra).
**Regla**: cualquier arranque coordinado de dos `AVAudioPlayerNode` debe usar un `AVAudioTime(hostTime:)` común, NO `at: nil`. Y al reprogramar, la base de tiempo del timer debe corresponder al instante y posición REALES de arranque del audio. Limitación: asume beat 1 en t=0 (sin downbeat/beatgrid real) — mejorar con beatgrid en Fase 2.

### [2026-06-02] — Drag biblioteca→deck re-importaba la pista (duplicado)
**Bug**: arrastrar una fila de la biblioteca a un deck creaba un duplicado en la biblioteca y re-analizaba BPM (lento), en vez de cargar la pista ya analizada.
**Causa**: `handleDrop` recibía solo la URL y siempre llamaba `importTracks(urls:)`, sin comprobar si esa URL ya estaba en `libraryService.tracks`.
**Fix**: en `handleDrop` se busca primero `libraryService.tracks.first(where: { $0.url == url })` y se reutiliza esa pista; solo se importa si no existe (caso: arrastre desde Finder).
**Regla**: al recibir un drop con una URL, comprobar SIEMPRE si el recurso ya existe en el modelo antes de importarlo. Importar es la última opción, no la primera.

### [2026-06-02] — Botón TEST "T" de debugging quedó en la UI
**Bug**: botón rojo "T" (acelera 2s y vuelve) visible en los controles de transporte; era solo para verificar TimePitch durante desarrollo.
**Fix**: eliminado el botón en `TransportControlsView` y el método `testSetRate(_:deck:)` en `AudioEngine` (verificado con grep que no quedaban referencias).
**Regla**: marcar el código de debugging con `// TEST` o `#if DEBUG` desde el inicio para poder localizarlo y quitarlo antes de release.
