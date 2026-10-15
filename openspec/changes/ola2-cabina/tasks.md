# Tasks — ola2-cabina

## 1. Motor (AudioEngine.swift)
- [ ] 1.1 `masterBus` (AVAudioMixerNode) + peak limiter (`kAudioUnitSubType_PeakLimiter`).
      Cadena: fader → filter → masterBus → limiter → mainMixerNode. Fallback: si el AU
      no instancia, masterBus → mainMixerNode directo (log, sin crash).
- [ ] 1.2 `filterA/filterB` (AVAudioUnitEQ 1 banda). Mapa knob: v<0 → resonantLowPass
      cutoff 20000×(200/20000)^(−v); v>0 → resonantHighPass cutoff 20×(8000/20)^v; v≈0 → bypass.
- [ ] 1.3 VU real: installTap en faderA/faderB (1024 frames), RMS → suavizado
      (attack inmediato, release exponencial) → `vuLevelA/B` en main thread.
      Quitar el proxy `fader.outputVolume` del timer.
- [ ] 1.4 `keyShift` (semitonos) en updateTimePitch: pitch = comp_keylock + keyShift×100.
- [ ] 1.5 `syncKey(deck:)`: distancia Camelot mínima en semitonos ((d×7+6) mod 12 − 6)
      del deck propio al otro; escribe deckState.keyShift. Sin pista/key en alguno → no-op.
- [ ] 1.6 `beatJump(deck:beats:)`: seek(to: posición ± beats×60/bpm) clamp [0, dur].
- [ ] 1.7 Grabación: `isRecording`, `startRecording()` (tap en limiter/masterBus →
      AVAudioFile WAV en ~/Music/Pulso Recordings/), `stopRecording()` → devuelve URL.
- [ ] 1.8 Persistir filter/keyShift en DeckSnapshot (sesión).

## 2. Estado (DeckState.swift)
- [ ] 2.1 `@Published var filter: Double = 0` (−1…+1)
- [ ] 2.2 `@Published var keyShift: Int = 0` (−6…+6) + `keyDisplay` refleja shift (p.ej. "4A +2")

## 3. UI
- [ ] 3.1 DeckView: knob FILTER (mismo componente que EQ) junto a LOW/MID/HIGH.
- [ ] 3.2 DeckView: botón KEY SYNC (junto a SYNC) + indicador de shift; clic derecho/long = reset.
- [ ] 3.3 DeckView: beat jump ◀◀4 ◀4 4▶ 8▶… (fila junto a LOOP; mínimo ±4/±8).
- [ ] 3.4 TopBarView: botón REC con estado (rojo parpadeo) + al parar, mostrar ruta del WAV.

## 4. Verificación (E2E con la app corriendo)
- [ ] 4.1 Build limpio (xcodegen + xcodebuild).
- [ ] 4.2 Meters: con los 4 stems muteados y deck sonando → VU cae a 0; desmutear → se mueve.
- [ ] 4.3 FILTER: sweep audible y knob visible en ambos extremos; centro = bypass.
- [ ] 4.4 KEY SYNC: cargar 2 pistas con keys distintas → shift calculado y key display actualiza.
- [ ] 4.5 Beat jump: saltos de ±4 beats mantienen el beatmatch (verificar contra panel).
- [ ] 4.6 REC: grabar ~30 s de mezcla → WAV existe, dura ~30 s y se reproduce.
- [ ] 4.7 Regresión: SYNC/phase-lock, stems, preescucha y crossfader siguen OK.
