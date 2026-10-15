# ROADMAP Features Pro — Pulso DJ

**Documento de producto** | Fecha: 2-jun-2026 | Versión: 1.0  
Owner: Nelson (Nelsitobcn) + Jordi Mauri

---

## 📊 Resumen ejecutivo

### Posición actual (MVP funcional)
Pulso está **6-9 meses atrás de table stakes 2026**, pero **16-18 meses por delante en infraestructura Apple Silicon**:
- ✅ Decks, crossfader, EQ, hot cues, loops, tempo, key lock, sync — funcional
- ✅ Análisis BPM + key Camelot al importar (TrackAnalyzer con Krumhansl-Schmuckler)
- ✅ Audio latency optimizado (AVAudioEngine grafo, pitch con AVAudioUnitTimePitch)
- ✅ Waveform interactivo con playhead
- ❌ Falta: STEMS en tiempo real (table stakes desde 2024 en VirtualDJ/Rekordbox/Serato)
- ❌ Falta: Key Sync automático (pitch-shift limpio cuando das pitch +/-)
- ❌ Falta: Beatgrid dinámico (el que puede sync fases en vivo)

### Ventaja competitiva real
1. **Únicamente nativo Apple Silicon** — latencia sub-5ms posible, 0 coste CPU vs modelos en nube
2. **Harmonic mixing Camelot YA existe en código** — solo falta Key Sync UI + UX
3. **Stems flags YA declarados en DeckState** — preparado para Core ML MDX/Demucs convertido a .mlmodel
4. **Track metadata structure lista** — solo agregar campos para lyrics, groove info

### Competencia que está aquí
| App | Stems | Key Sync | Beatgrid dinámico | IA Lyrics | Sugerencias IA |
|-----|-------|----------|-------------------|-----------|----------------|
| **VirtualDJ 2026** | ✅ En vivo | ✅ Fluido | ✅ BPM Stabilizer | ✅ (nuevo) | ✅ StemSwap |
| **Rekordbox 7** | ✅ Análisis | ✅ Key Sync | ⚠️ Básico | ❌ | ✅ Radar |
| **Serato 4** | ✅ En vivo | ⚠️ Manual | ❌ | ❌ | ❌ |
| **djay Pro** | ⚠️ Parcial | ⚠️ Manual | ❌ | ❌ | ✅ (Spotify/Apple Music) |
| **Pulso (hoy)** | ❌ | ❌ | ❌ | ❌ | ❌ |

### Diferenciadores posibles (Pulso en 9 meses)
- **Harmonic mixing inteligente**: busca tonalidad compatible automáticamente sin forzar (fuzzy keymixing)
- **Lyrics en el waveform**: transcripción Whisper pre-calculada superpuesta en timeline
- **Groove detection**: identifica secciones (intro, build, drop, outro) con IA local
- **Stem swap básico**: sustituye batería o vocal en vivo (MLX multimodal)

---

## 📋 Tabla de features — Prioridad, dificultad y apoyo en código

### Ola 1: TABLE STAKES (lanzamiento MVP Pro)
Necesarios para competir. Realista: **6-8 semanas solo dev con IA**.

| Feature | Categoría | Qué hace | Por qué importa | Dificultad | ¿Qué YA existe en Pulso? | Dónde empezar |
|---------|-----------|----------|-----------------|-----------|------------------------|---------------|
| **STEMS en vivo (Voces/Batería/Bajo/Melodía)** | Table stakes | Aisla 4 pistas de audio; mute vocal/batería/bajo/melodía independiente | SIN stems, estás fuera del mercado DJ 2026. El 80% de los DJs pro lo usan diario | Alta | DeckState flags `stemVocalMuted`, `stemBassMuted`, `stemDrumsMuted`, `stemMelodyMuted` + UI parcial. NO hay motor de stems | TrackAnalyzer: agregar paso 1) cargar .mlmodel Demucs convertido a Core ML (buscar `demucs-v4-4stems.mlmodel` en comunidad ML); paso 2) llamar en `analyze()` para procesar audio al importar; paso 3) guardar 4 buffers en Track (stemVocal, stemDrums, stemBass, stemMelody) |
| **Key Sync (pitch-shift limpio)** | Table stakes | Al cambiar tempo (± %), el pitch de la otra pista sube/baja proporcionalmente. Mantiene tonalidad compatible automáticamente | Permite mezclar sin desajustar armonía. Estándar en Serato/Rekordbox | Media | MusicalKey enum Camelot + `isCompatible()` método; AVAudioUnitTimePitch YA en grafo. Falta: UI botón Key Sync + algoritmo que detecte cambio de tempo en deck B y ajuste pitch A automáticamente | AudioEngine: nueva propiedad `@Published var keySyncEnabled: Bool = false`; en setter de `tempo(for:)` agregar lógica: "si keySyncEnabled y cambio tempo en B, calcula pitch delta necesario para mantener key compatible en A"; aplicar a pitchA/pitchB |
| **Beatgrid dinámico (sync de fase)** | Table stakes | Detecta transientes en tiempo real y ajusta la grid automáticamente. Permite sync suave incluso en canciones con tempo inestable (funk, rock, afrobeat) | VirtualDJ BPM Stabilizer + djay tienen esto. DJs pro lo exigen para géneros no-electrónicos | Alta | Análisis BPM básico en TrackAnalyzer (onset detection + autocorr). NO hay grid dinámico ni sync de fase | TrackAnalyzer: extender `detectBPM()` para retornar NO solo BPM final sino array de transientes detectadas (timestamps exactos de onsets). AudioEngine: nueva class `BeatGridAnalyzer` que mida tiempo real de playback vs grid esperado; al detectar drift >50ms, ajusta timeline mediante `nodeTime()` manipulation (muy sensible, requiere testing en Mac físico) |
| **Suggester IA básico (siguiente pista)** | Table stakes (expectativa) | Escribe: "set de salsa de los 90" → sugiere 5 canciones de playlist compatible por BPM/key/energy | Estándar en VirtualDJ AIPrompt, Rekordbox Radar. Hace DJing más rápido | Baja-Media | Track struct tiene BPM + key + energy + genre. LibraryService accede JSON. NO hay modelo IA de recomendación | LibraryService: agregar método `suggestNextTrack(context: String, basedOn: Track) -> [Track]`. Usar MLX Swift binding (si existe) o llamar a API local (FastAPI endpoint que corre Ollama qwen2.5-coder:7b localmente en Mac Studio). Alternativa sin IA: búsqueda heurística por BPM±5, key compatible, energy similar. Fase 2 agregar LLM |

---

### Ola 2: DIFERENCIADORES Apple Silicon (semanas 8-16)
Únicas ventajas reales vs competencia. Realista: **4-5 semanas solo dev con IA** si Ola 1 lista.

| Feature | Categoría | Qué hace | Por qué importa | Dificultad | ¿Qué YA existe? | Dónde empezar |
|---------|-----------|----------|-----------------|-----------|-----------------|---------------|
| **Key Sync Fuzzy (búsqueda inteligente tonalidad)** | Diferenciador | Al cambiar tempo en un deck, busca automáticamente la tonalidad COMPATIBLE más cercana en el otro deck en lugar de forzar transponer | Evita transposiciones feas. VirtualDJ NO lo tiene. Serato NO. Es ÚNICO de Pulso si lo haces bien | Media | MusicalKey.isCompatible() YA existe. `suggestNextTrack()` de Ola 1 puede usar lógica similar | AudioEngine: cuando tempo cambia y keySyncEnabled, llamar a `LibraryService.suggestCompatibleKeys(from: trackA.key, targetEnergy: trackB.energy)`. Retorna array de MusicalKey ordenadas por compatibilidad + proximidad en Camelot wheel |
| **AI Lyrics superpuestas en waveform** | Diferenciador / WOW | Carga canción → Whisper transcribe a .srt en background (sub 5s en Mac Studio M3 Max) → overlay timeline texto sincronizado | Permite DJs ver dónde están los versos, drops, refrains SIN memorizar. Factor WOW. VirtualDJ lanzó en Q1 2026 | Media (pre-cálculo) | Track struct. WaveformView dibuja waveform. NO hay transcripción. Whisper Core ML existe (apple/ml-stable-diffusion) pero es difícil; más fácil usar API local OpenAI-compat | TrackAnalyzer: agregar paso post-análisis BPM. Llamar a `whisper.cpp` vía shell (si .xcframework compilado) o endpoint local `http://localhost:8000/transcribe` (FastAPI + Whisper server corre en Mac Studio background). Guardar .srt en Track metadata. WaveformView: agregar subvista de lyrics sincronizadas al playhead |
| **Groove detection (secciones automáticas)** | Diferenciador | Detecta intro/build/drop/outro automáticamente; DJ ve dónde son los moments clave sin auditar la canción | Acelera curation. Mejora flow sets | Alta | AudioEngine tiene análisis BPM/key. NO hay detección de estructura | TrackAnalyzer: usar espectrograma (FFT) + análisis de energía dinámica para detectar cambios de "groove" (secciones). Implementar `detectStructure()` que retorne array de Section(type, startTime, endTime, energy) |
| **Stem Swap básico (batería/vocal swap en vivo)** | Diferenciador | Carga 2 canciones. Toca "swap drums en deck A con drums de deck B" → ejecuta (requiere tener stems de ambas previamente aislados) | DDJ-GRV6 + VirtualDJ StemSwap. Muy DJ workflow | Alta | Stems Ola 1 necesaria como prerequisito. AudioEngine puede mezclar múltiples pistas | AudioEngine: agregar método `stemSwap(fromDeck: DeckID, toDeck: DeckID, stemType: StemType)` que recoloca buffer de stem en vivo. Latencia sensible; requiere testing |

---

### Ola 3: Factor WOW (semanas 16+)
Polish y diferenciación premium. Realista: **ongoing**, menor prioridad que Ola 1-2.

| Feature | Descripción | Realismo |
|---------|-------------|----------|
| **Groove Circuit visual** | animación 3D de espectrograma en vivo que responda a los stems y energía | Semanal trabajo mínimo si SpriteKit/SceneKit, pero no crítico para v1 Pro |
| **Integración Beatsource API** | busca y descarga canciones legalmente desde dentro de la app | Importante para monetización pero backend: soporte Beatsource requerido (esperar respuesta SDK) |
| **Sync remoto iPad ↔ Mac vía CloudKit** | sets guardados en la nube, sincronizados entre dispositivos | Infraestructura CloudKit lista, 3-4 días integración |
| **Playlist IA generada (Prompt natural)** | "hazme un set para boda energético" → genera playlist completa | LLM local + búsqueda heurística LibraryService; Ola 2 base existiría |
| **Visuales IA en vivo** | shader que responda a stems/BPM en tiempo real (similar Rekordbox beatmatch visuals) | Metal graphics; 2-3 semanas, baja prioridad |

---

## 🏗️ Roadmap temporal — 3 olas

```
Hoy (2-jun)     |────────── OLA 1: 6-8 semanas ──────────|
                v                                          v
              6-ago: MVP Pro lanzable (Stems + KeySync + Beatgrid)
              
              |────────── OLA 2: +4-5 semanas ──────────|
              v                                           v
            2-oct: Diferenciadores únicos (Fuzzy Key + Lyrics + Groove)
            
            |────────── OLA 3: ongoing ──────────|
            v                                     v
          Ene 2027: Polish + integraciones streaming (Beatsource)
```

### Ola 1 — Hito (6 de agosto 2026): MVP Pro lanzable
**Qué hace Pro frente a Free:**
- ✅ Stems on/off (4 pistas)
- ✅ Key Sync automático (mantiene tonalidad compatible)
- ✅ Beatgrid dinámico (sync fase en vivo)
- ✅ Suggester IA (siguiente pista compatible)

**Criterio aceptación:** 
- Las 4 features funcionan en Mac Studio sin crashes
- Latencia playback <5ms (CRÍTICO para DJs)
- 10 canciones de prueba (electrónica, funk, rock, salsa) dan stems limpios
- Key Sync fuzzy busca tonalidad correcta ≥80% de veces

### Ola 2 — Hito (2 de octubre 2026): Diferenciados
- ✅ Todo Ola 1 + pulido
- ✅ Fuzzy key, lyrics, groove detection funcionales
- ✅ Preparado para beta testers (invitar DJs reales)

### Ola 3 — Hito (enero 2027): Premium
- ✅ CloudKit sync, integraciones streaming (si Beatsource responde)
- ✅ UI pulida, animaciones
- ✅ Listo para producción App Store

---

## 🔧 Notas técnicas — Por dónde empezar (Ola 1)

### 1. STEMS en vivo
**Archivo central:** `TrackAnalyzer.swift`

```swift
// Paso 1: Descargar modelo Demucs Core ML
// Buscar en Hugging Face: apple/ml-stable-diffusion
// O usar repo: demucs/demucs (archivo demucs-v4-4stems.mlmodel compilado)
// Guardar en: Pulso/Resources/Models/demucs-v4-4stems.mlmodel

// Paso 2: En TrackAnalyzer.analyze(), tras detectBPM/key:
func analyze(track: inout Track) async {
    // ... existing BPM, key, waveform ...
    
    // NUEVO: Stem separation
    if let stemsData = await separateStems(url: track.url) {
        track.stemVocal = stemsData.vocal
        track.stemDrums = stemsData.drums
        track.stemBass = stemsData.bass
        track.stemMelody = stemsData.melody
    }
}

private func separateStems(url: URL) async -> StemsData? {
    // 1. Cargar .mlmodel Demucs
    // 2. Preprocessar audio (normalizar, resample a 16kHz si necesario)
    // 3. Llamar modelo Core ML (inference ~3-5s en M3 Max)
    // 4. Retornar 4 AVAudioBuffer
}
```

**Riesgos:**
- El .mlmodel de Demucs pesa ~350MB descargado (lento primer uso). Solución: descarga background on first launch.
- Latencia inference: 3-5s en M3 Max es aceptable (background); en Mac Mini M1 puede llegar a 8s.
- Qualidad stems: Demucs v4 es líder; alternativa open-source espectrogramaK-means (peor calidad, más rápido).

**Decision:** usar Demucs v4 Core ML. Si tamaño modelo es problema, hacer downsampling audio antes de inference (trade-off: peor stems pero 50% más rápido).

---

### 2. Key Sync automático
**Archivo central:** `AudioEngine.swift`

```swift
// DeckState ya tiene @Published var tempo
// AVAudioUnitTimePitch ya está en grafo (pitchA, pitchB)

// Agregar a AudioEngine:
@Published var keySyncEnabled: Bool = false

// En el setter de tempo (cuando usuario cambia tempo en deck B):
func setTempo(_ newTempo: Double, for deckID: DeckID) {
    let deck = (deckID == .left) ? deckA : deckB
    let otherDeck = (deckID == .left) ? deckB : deckA
    
    deck.tempo = newTempo
    
    // Si Key Sync activo, ajusta pitch del otro deck
    if keySyncEnabled, let otherKey = otherDeck.track?.key, let myKey = deck.track?.key {
        let pitchShift = calculatePitchShiftForKeySync(
            fromKey: myKey,
            toKey: otherKey,
            tempoRatio: newTempo / otherDeck.tempo
        )
        let targetPitch = 1.0 + pitchShift / 12.0 // pitchShift en semitones
        applyPitch(targetPitch, to: deckID == .left ? pitchB : pitchA)
    }
}

private func calculatePitchShiftForKeySync(
    fromKey: MusicalKey,
    toKey: MusicalKey,
    tempoRatio: Double
) -> Double {
    // Usa MusicalKey.isCompatible() para encontrar transposición correcta
    // Si keys compatibles, retorna 0 (sin cambio)
    // Si no compatibles, busca transposición mínima aceptable
    // Retorna semitones (±12 máximo)
}
```

**Riesgos:**
- `AVAudioUnitTimePitch` tiene latencia ~100ms en cambios de parámetro (aceptable pero perceptible).
- Decisión: ¿aplicar cambio pitch suavemente (ramp 500ms) o inmediato? Suave es DJ-friendly.

---

### 3. Beatgrid dinámico + sync de fase
**Archivo central:** `TrackAnalyzer.swift` + `AudioEngine.swift`

```swift
// TrackAnalyzer: extender detectBPM para retornar transientes
func detectBPM(buffer: AVAudioPCMBuffer, sampleRate: Double) -> (bpm: Double, onsets: [TimeInterval]) {
    // Detecta onsets usando onset strength (existente)
    // Retorna array de timestamps donde hay transientes
}

// AudioEngine: nueva class
actor BeatGridAnalyzer {
    func syncPhases(deckA: DeckState, deckB: DeckState, onsets: [TimeInterval]) {
        // Mide diferencia de fase entre ambos decks
        // Si drift > threshold, ajusta timeline
        // SENSIBLE: usa AVAudioPlayerNode.nodeTime() + hostTime correction
    }
}
```

**Riesgos:**
- **MÁS CRÍTICO:** manipular fase de playback en vivo requiere precision sub-frame (~23μs). Esto requiere testing extensive en Mac real.
- Alternativa más simple (v1): mostrar grid visual en waveform; DJ ajusta manualmente. Próxima versión: sync automático.

---

### 4. Suggester IA básico
**Archivo central:** `LibraryService.swift`

**Opción A (sin IA — v1.0):**
```swift
func suggestNextTracks(basedOn track: Track, limit: Int = 5) -> [Track] {
    let library = loadLibrary()
    return library
        .filter { t in
            // BPM ±5
            abs(t.bpm ?? 0 - (track.bpm ?? 0)) <= 5 &&
            // Key compatible (Camelot wheel)
            t.key?.isCompatible(with: track.key ?? .c1A) == true &&
            // Energy similar (±0.15)
            abs(t.energy ?? 0 - (track.energy ?? 0)) <= 0.15 &&
            t.id != track.id
        }
        .sorted { a, b in
            // Ordenar por similitud total (BPM match + energy match)
            similarityScore(a, to: track) > similarityScore(b, to: track)
        }
        .prefix(limit)
}
```

**Opción B (con IA — v1.1):**
```swift
// Llamar a LLM local (Ollama qwen2.5-coder:7b en Mac Studio)
func suggestNextTracksWithAI(prompt: String, basedOn track: Track) async -> [Track] {
    let apiCall = """
    POST http://localhost:11434/api/generate
    {
        "model": "qwen2.5-coder:7b",
        "prompt": "DJ está tocando \(track.artist) - \(track.title) (\(track.genre)). 
                   El DJ quiere: \(prompt). Sugiere 5 canciones de esta playlist: \(library.map{$0.title}.joined(separator: ", "))"
    }
    """
    // Parse respuesta, retorna tracks
}
```

**Riesgos:**
- v1 sin IA es MVP rápido, funciona bien.
- v1.1 con Ollama depende de tener Ollama corriendo en Mac Studio background (siempre arriba en nuestro setup).

---

## ⚠️ Decisiones abiertas y riesgos

### Críticos (Ola 1)
| Decisión | Opciones | Impacto |
|----------|----------|--------|
| **Modelo Stems** | Demucs v4 (350MB, ~3-5s) vs. Espectrograma K-means (peor calidad, 1-2s) | Calidad producto. Demucs es estándar pero pesado. |
| **Latencia máxima aceptable** | <5ms (estándar DJ) vs. <10ms (usuario casual) | Si superamos 10ms, será hard sell vs. Rekordbox/Serato |
| **Tamaño .mlmodel en disco** | ¿Incluir descargado en bundle app? ¿O lazy-load primera vez? | Bundle crece 350MB; lazy-load primera vez es lenta pero ok para DJ pro |
| **Distribución app (pre-App Store)** | TestFlight vs. GitHub releases notarizadas | TestFlight es más controlado; GitHub releases es más abierto para beta testers Jordi/amigos |

### Técnicos (Ola 1-2)
| Riesgo | Probabilidad | Mitigación |
|--------|-------------|-----------|
| **Stems inference latency** | Media (depende de hardware usuario) | Lazy-load model on first import; mostrar progress. En Mac Mini M1 será 8s, aceptable. |
| **Key Sync pitch artifacts** | Media | AVAudioUnitTimePitch tiene artefactos a ciertos ratios. Testing en Mac real. |
| **Beatgrid sync drift** | Alta | Versión v1.0: solo grid visual; v1.1: sync automático tras testing. |
| **LLM local Ollama latency** | Media | Si Ollama slow, timeouts. Fallback a heurística búsqueda. |

---

## 📦 Backlog técnico — Issues/PRs sugeridas

### Ola 1
1. **feat: stem separation Core ML** — Descargar Demucs v4, integrar TrackAnalyzer, guardar en Track
2. **feat: key sync automation** — Agregar UI botón, lógica setTempo(), testing key compatible
3. **feat: beatgrid dynamic sync** — Extender TrackAnalyzer onsets detection, AudioEngine sync logic (VERSIÓN VISUAL PRIMERO)
4. **feat: suggester heuristic** — LibraryService método suggestNextTracks(), UI picker de siguientes pistas

### Ola 2
5. **feat: key sync fuzzy keymixing** — suggestCompatibleKeys() logic, UX mejor
6. **feat: lyrics transcription whisper** — TrackAnalyzer + Whisper Core ML (o API local), WaveformView overlay
7. **feat: groove detection** — detectStructure() en TrackAnalyzer, UI markers en waveform

---

## 🎯 Criterio de éxito

### MVP Pro lanzable (6-ago-2026)
- [ ] STEMS: en vivo mute 4 pistas, ≥80% de canciones reconocidas correctamente
- [ ] KEY SYNC: al cambiar tempo, pitch del otro deck se ajusta automáticamente, mantiene tonalidad compatible
- [ ] BEATGRID: grid visual es preciso; sync automático es opcional (v1.1)
- [ ] SUGGESTER: al menos heurístico, retorna 5 pistas compatibles por BPM/key/energy
- [ ] **Latencia:** max 10ms playback delay, stems inference <5s (M3) / <8s (M1)
- [ ] **Estabilidad:** 10 sesiones de 1h sin crashes, audio sync limpio

### Diferenciador lanzable (2-oct-2026)
- [ ] TODO de MVP Pro +
- [ ] Fuzzy key search funcional
- [ ] Lyrics transcripción visible en waveform
- [ ] Groove detection markers
- [ ] Beta testing con 5-10 DJs reales (incl. Jordi)

---

## 📞 Contactos / Next Steps

- **Nelson**: Product, arquitectura, coordinación Jordi
- **Jordi Mauri**: DJ domain expert, testing real workflow, feedback features
- **Beatsource**: Contactar SDK para v1.1 (onda streaming integration)

**Next immediate action:**
1. Descargar Demucs v4 Core ML (.mlmodel), compilar y testar inference en Mac Studio
2. Crear rama `feat/stems-ola1` 
3. Escribir TrackAnalyzer.separateStems() stub con Core ML inference call
4. Testing con 3 canciones (1 electrónica, 1 funk, 1 rock)

---

# ANEXO — Auditoría 23-jun-2026 (Fugu: Gemini propone + DeepSeek audita)

> **Método:** auditoría vía `/fugu` (worker Gemini 2.5 Pro, verificador adversarial DeepSeek V4).
> El Verifier marcó ambas tandas **NO_SEGURO** y encontró fallos físicos/técnicos reales en
> las propuestas crudas. **Lo de abajo ya está corregido con los hallazgos del Verifier** —
> no copiar la propuesta cruda de Gemini sin estas correcciones.
> **Marco:** Pulso es herramienta PARTICULAR de Nelson+Mauri, NO comercial → sin atadura de
> licencias de API comerciales (las restricciones de Spotify DJ-terms etc. no aplican a uso privado).

## A1 — SYNC / Beatmatching: por qué sigue cojo (diagnóstico confirmado en código)

### Bug raíz (confirmado leyendo el código)
**Guerra de escritura sobre `pitch.rate`.** Dos controladores escriben el MISMO parámetro sin árbitro:
- `DeckView.swift:381` — slider tempo → `applyTempo()` → `pitch.rate` (`AudioEngine.swift:349`)
- `AudioEngine.swift:463` — `phaseLockTimer` cada 100ms → `slavePitch.rate`

Al mover el slider del slave con SYNC activo, el timer lo pisa 10×/seg → "lo hace muy mal" (Nelson).

### 3 fallos más hallados en el código (no documentados antes)
1. **El `TrackAnalyzer` NUNCA calcula beatgrid ni downbeat.** Devuelve solo `track.bpm` (un número). El SYNC alinea contra `t=0` porque no tiene otra cosa. `Track`/`DeckState` no tienen campo `beatGrid`/`firstBeat`. → causa raíz del "downbeat no real".
2. **`beatMasterFile` se congela al arrancar el lock** (`AudioEngine.swift:435`) — si el master cambia tempo, el slave persigue una fase fantasma.
3. **El analyzer solo mira los primeros 60s** (`TrackAnalyzer.swift:238`) → BPM de intro ≠ BPM del drop.

### Arquitectura correcta (corregida por el Verifier)
**Desacoplar TEMPO de FASE:**
- `AVAudioUnitTimePitch` (o Rubber Band) = SOLO tempo base. Slider + BPM-objetivo escriben aquí.
- Phase-nudge = **ring buffer con lectura fraccional** (NO `AVAudioUnitVarispeed` — Gemini lo propuso pero el Verifier lo desmintió: Varispeed cambia pitch Y tempo a la vez → el pitch oscilaría audible en cada micro-corrección).
- Idealmente el lazo de control en **render thread** (sample-accurate), no en `Timer`/main thread (5-10ms de jitter — fallo no señalado por Gemini).
- `TrackAnalyzer` debe generar **beatgrid + downbeat real** y guardarlo en `Track`. Sin esto, el auto-mix por frases es imposible.

### Fix barato e inmediato (Swift puro, SIN C++)
**Árbitro de escritura:** al tocar el slider con SYNC activo → o se desactiva SYNC, o el slider mueve la `baseRate` del lock en vez de pisar `pitch.rate` directo. Mata el bug que más molesta HOY. 1 sesión.

### Rubber Band (decisión con Mauri)
`AVAudioUnitTimePitch` (phase vocoder vDSP) "mancha" transientes y no expone control fase/tempo separado. **Rubber Band Library** (LGPL, open-source) sí lo expone (`setTimeRatio` vs `setPitchScale`). Pero integrarla = wrapper Obj-C++ (`.mm`) + AudioUnit v3 custom + thread-safety por buffer (la API de RB es de bloque/offline → riesgo técnico real que Gemini subestimó). Es ingeniería seria. Decisión arquitectónica Nelson+Mauri.

---

## A2 — Soberanía de fuentes musicales (uso particular)

### Estado de herramientas en el Mac (verificado 23-jun-2026)
- ✅ `yt-dlp` 2026.03.17 · ✅ `ffmpeg` 8.1.1 · ✅ Ollama local (qwen3-coder gratis)
- ❌ **BlackHole NO instalado** → loopback de navegador requiere `brew install blackhole-2ch`
- ✅ `Track` ya tiene `url/bpm/key/energy/genre` + `isCompatible()` Camelot → sugerencia armónica con 50% hecho

### 🥇 FASE 2 — núcleo soberano

**F2.1 — YouTube como fuente de deck** (★ feature soberana)
- yt-dlp baja el audio → `TrackAnalyzer` calcula BPM/key/beatgrid → queda local para siempre. Convierte todo YouTube en biblioteca propia.
- 🔴 **Corrección Verifier (crítica):** NO usar URL de streaming directa (`yt-dlp --get-url`) — **expira en ~6h y muere en runtime sin avisar**. Para herramienta propia: **descargar el archivo completo primero**, luego cargar local. Sin streaming frágil.
- 🔴 **Inyección de comandos:** títulos de playlist van como args a yt-dlp. Un título con `"; rm -rf /` se ejecutaría. **OBLIGATORIO** pasar args como array (`Process.arguments`), NUNCA string interpolado.
- 🔴 Caché necesita límite de tamaño + evicción LRU, o llena el disco (`PULSO_CACHE` crece infinito).

**F2.2 — Importador universal de playlists** (Spotify/Apple/YouTube/SoundCloud/.m3u/.xspf → crate)
- Parsea título-artista → "Resolvedor": busca primero en biblioteca local (fuzzy), si no, lo baja de YouTube. Estado por track: local / youtube / no-encontrado.
- ⚠️ **Verifier:** scraping HTML (SwiftSoup) de Spotify/Apple es **frágil** (cambio de DOM → crate vacía sin explicación). Lo estable: `.m3u/.xspf` (texto plano) + API YouTube (key personal gratis). Spotify/Apple = "best effort", asumir mantenimiento.

### 🥈 FASE 3 — descubrimiento e inteligencia

**F3.1 — Crates de tendencia + "Mauri-Bot" (Ollama local)**
- Scrape Beatport/Traxsource/1001Tracklists Top 100 (SwiftSoup, 1×/día) → crates virtuales. Click en track → activa el Resolvedor de F2.
- Ollama local filtra "qué de este Top es imprescindible PARA TI" según tu biblioteca + sets de Mauri.
- 🔴 Verifier: Ollama puede alucinar JSON → validar schema + retry. Caso borde fácil de cubrir.

**F3.2 — Navegador como deck (BlackHole loopback)**
- Captura audio del sistema (Brave/Mixcloud/SoundCloud en vivo) → deck de Pulso con EQ/filtros tiempo real.
- 🔴 **Verifier crítico:** el código de Gemini **NO compila en macOS** (usó `AVAudioSession`, que es API de iOS). En macOS: CoreAudio + `AudioObjectGetPropertyData`. El "Aggregate/Multi-Output Device" afecta a TODO el audio del sistema (subir volumen cambia la señal de entrada) — acoplamiento que hay que manejar. Factible pero más trabajo del que pintó Gemini. Requiere instalar BlackHole.

### 🌙 MOONSHOT

**M.1 — ShazamKit "taggear y robar"**
- Escuchas un DJ set online → botón Taggear → ShazamKit lo identifica → se baja de YouTube y entra analizado a la biblioteca en ~15s.
- 🔴 Verifier: ShazamKit en macOS desde BlackHole **no está documentado como soportado** — puede fallar en runtime sin error de compilación. Probar antes de asumir.

### Orden recomendado (más capacidad / menos riesgo)
0. **Árbitro de escritura SYNC** (A1) — prerequisito: sin SYNC fino las fuentes nuevas no se mezclan bien.
1. **YouTube→deck con descarga+caché** (F2.1, NO streaming).
2. **Sugerencia armónica local** (Camelot+BPM+energía — 50% hecho en `Track.isCompatible()`).
3. **Mauri-Bot Ollama** (F3.1) — gratis, local, único.
4. Loopback navegador (F3.2) + Shazam (M.1) cuando la base sea roca.

### Resumen fallos que el Verifier salvó (no repetir)
| Propuesta cruda Gemini | Fallo (DeepSeek) | Corrección |
|---|---|---|
| Varispeed para phase-nudge | Cambia pitch+tempo → oscila audible | Ring buffer fraccional |
| URL streaming yt-dlp | Expira ~6h, muere en runtime | Descargar archivo completo |
| Título → string a yt-dlp | Inyección de comandos | Args como array |
| `AVAudioSession` (loopback) | Es API iOS, no compila macOS | CoreAudio nativo |
| Caché sin límite | Llena disco | Evicción LRU |
| Ollama → JSON directo | Alucina → crash | Validar schema + retry |
| ShazamKit desde BlackHole | No documentado soportado | Probar antes |

---

# ANEXO B — Beatgrid Sesión 1 (1-jul-2026): veredicto concilio + research + qué se hizo

> **Método:** research NotebookLM **deep** (98 fuentes, notebook DJ `8885a4a5`) + concilio
> multi-modelo real (Gemini 2.5 Pro + Codex + Claude, prompts paralelos con el código real).
> Decisión owner: **"solo lo robusto y barato"**.

## B1 — Veredicto: CONSENSO UNÁNIME 4/4

**Beatgrid + downbeat en SWIFT PURO + Accelerate/vDSP, Dynamic Programming tipo Ellis 2007.
NADA de librería externa.**

**Hallazgo crítico (solo salió por NBLM, invalida meter aubio):** aubio NO es BSD como cree
mucha gente — es **GPL-3**. aubio, BTrack, QM-DSP, Essentia → **todas GPL/AGPL copyleft = veneno
para App Store** (Pulso Fase 3). Linkar cualquiera bloquea la distribución. → Swift puro no es
solo lo barato, es lo único legalmente viable a futuro. (BeatNet/Beat This! son MIT pero ML
pesado: modelo ~97MB + ONNX/CoreML, descartado para "barato".)

**Todos coinciden en:** beats por DP Ellis (NBLM dio el código `AccelBeatTracker` casi listo);
downbeat heurístico 4/4 = energía sub-bass <150Hz + cambio armónico chroma cada 4 beats, **es
heurística NO certeza → la UI DEBE dejar corregir el downbeat a mano** (Sesión 2); analizar
**track entero** (el shortcut de 60s es obsoleto en M3); `Double` siempre (0.02 BPM error = 60ms
drift en 6min = clash audible).

**Grid fijo vs dinámico:** Mixxx/Rekordbox usan **híbrido piecewise-constant** (segmentos de
tempo local constante). Decisión: **empezar fijo** (BPM+fase+downbeat); el híbrido solo si
Nelson nota drift en tracks con batería en vivo. No sobre-ingenierizar la v1.

## B2 — Qué se implementó (rama `feat/beatgrid-sesion1`, commit 89b02d8)

- `Track.BeatGrid` (beats[], downbeatIndex, beatsPerBar, bpm, confidence, isVariableTempo).
  Codable, persistencia round-trip JSON verificada. `bpm` legacy intacto → no rompe UI/SYNC/sugerencias.
- `TrackAnalyzer`: fix 60s → track entero (cap 12min).
- `BeatGridAnalyzer.swift` (nuevo, 0 deps): onset spectral-flux multibanda (mono mix) →
  autocorrelación lag-a-lag (`vDSP_dotpr`) ponderada log-normal → DP Ellis → beats → downbeat
  sub-bass con guard de confianza (devuelve `nil` honesto si la fase del "1" es ambigua).
- Auto-test `PULSO_BEATGRID_TEST` (reproducible).

**Verificado (output ejecutable):** Kick 120→grid.bpm 120.1 (119 beats, 0.499s); Kick 128→127.9
(127 beats, 0.470s). Beats en posiciones reales equiespaciadas, no t=0. Build OK, sin crash.

**Verifier Fugu cazó 2 bugs reales (arreglados + reverificados):** (1) overflow `vDSP_conv`
(escribía 2N-1 en buffer de N → corrupción memoria) → reescrito a `vDSP_dotpr` lag-a-lag, imposible
desbordar; (2) `downbeatIndex` devolvía fase como índice ambiguo → ahora `nil` con guard ≥15%.

## B3 — Pendiente Sesión 2 (conectar SYNC + UI)

- **Conectar el SYNC al beatgrid**: `AudioEngine.startPhaseLock` hoy alinea fase *dentro de un
  beat* contra t=0 (`mTime mod beatMasterFile`). Cambiar a: buscar el beat real más cercano en
  `beatGrid.beats` del master y del slave, alinear por `beatIndex % beatsPerBar` si hay downbeat
  fiable, si no beat-a-beat. La fase sale del grid, el BPM del time-stretch.
- **UI "Set Downbeat Here"**: botón para fijar el "1" a mano (la heurística sub-bass falla en
  salsa/funk — confirmado: en kicks puros sin armonía devuelve `nil`, correcto).
- **Casos borde anotados (no bloquean, Verifier Fugu):** validar sampleRate variable (VBR),
  análisis en background para tracks de 12min, fusión bpm-legacy/grid por confianza. Menores.

---

**Última revisión:** 1-jul-2026 (Anexo B — beatgrid Sesión 1)  
**Próxima revisión:** 15-ago-2026 (post-Ola 1 MVP) · o al arrancar Sesión 2 (SYNC+UI)
