# Ola 2 — Cabina: del demo funcional a herramienta de DJ

## Por qué

El E2E del 11-jul-2026 confirmó que el flujo completo funciona (YouTube → deck → SYNC → stems),
pero Nelson lo resume: "no es ni la sombra de Serato". Los gaps que un DJ nota en los
primeros 5 minutos son de CABINA, no de features: metering falso, sin gain staging, sin
filtro DJ, sin key sync, sin beat jump, sin grabación.

## Qué cambia

1. **VU meters reales** — `installTap` post-fader por deck, RMS con suavizado (attack rápido,
   release ~300 ms). Sustituye el proxy `fader.outputVolume` (LEARNINGS 2026-07-11).
2. **Master bus + limiter** — mixer `masterBus` propio entre faders y `mainMixerNode` con un
   peak limiter (AudioUnit `kAudioUnitSubType_PeakLimiter`). Evita clipping al sumar 2 decks.
3. **FILTER por deck** — knob único −1…+1 estilo Pioneer: negativo = low-pass sweep
   (20 kHz→200 Hz), positivo = high-pass sweep (20 Hz→8 kHz), 0 = bypass. Nodo
   `AVAudioUnitEQ` (resonantLowPass/resonantHighPass) entre fader y masterBus.
4. **Key Shift + Key Sync** — `keyShift` en semitonos (−6…+6) aplicado al `AVAudioUnitTimePitch`
   (100 cents/semitono, sumado a la compensación de keylock). Botón KEY SYNC: calcula la
   distancia Camelot entre decks (+1 rueda = +7 semitonos, mod 12, camino mínimo) y ajusta
   el keyShift del deck propio para casar con el otro.
5. **Beat jump** — botones ±4/±8 beats: seek relativo de `beats × 60/bpm` segundos (tiempo de
   archivo; el grid no se toca).
6. **Grabación de set** — botón REC en la barra superior: tap en el bus master → WAV en
   `~/Music/Pulso Recordings/`. Parar = cerrar archivo y mostrar ruta.

## Qué NO cambia

- Pipeline existente (player/stems → stemSum → pitch → eq → fader) intacto; el filter y el
  masterBus se insertan DESPUÉS del fader, así SYNC/phase-lock/stems no se ven afectados.
- La preescucha sigue por su canal propio.
- iOS: sin cambios de comportamiento (mismos nodos, sin salida dual).

## Fuera de alcance (Ola 3)

- Salida de auriculares independiente (cue bus a segundo dispositivo CoreAudio) — requiere
  segundo AVAudioEngine y ring buffer por deck; se especificará aparte.
- FX creativos (echo, roll, flanger), slip mode, quantize de hot cues, MIDI.

## Impacto

- `AudioEngine.swift` (grafo + observadores + API nueva), `DeckState.swift` (+2 published),
  `DeckView.swift` (knob FILTER, KEY SYNC, beat jump), `TopBarView.swift` (REC),
  `CenterControlsView.swift` (sin cambios — ya lee vuLevelA/B).
- Riesgo principal: reconexión del grafo (formatos). Mitigación: conexiones nuevas con
  `format: nil` igual que las existentes; limiter con bypass de fallback si el AU no carga.
