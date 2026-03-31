# CLAUDE.md — Pulso DJ
## Última revisión: 2026-03-31

> App nativa macOS + iPadOS para DJs profesionales.
> Mezcla de música con IA, integración con music pools y exportación monetizable.

---

## Equipo

| Persona | Rol |
|---------|-----|
| Nelson (Nelsitobcn) | Owner, product manager, programador con IA |
| Jordi Mauri | Co-desarrollador senior, experto DJ, conocimiento del dominio |

---

## Arquitectura

| Capa | Tecnología | Notas |
|------|-----------|-------|
| UI | SwiftUI | Nativa macOS + iPadOS, código compartido |
| Audio engine | AVFoundation + Core Audio | Latencia ultra-baja, nativo Apple |
| IA / Stems | Core ML + Apple Neural Engine | Modelo Demucs convertido a .mlmodel — Fase 2 |
| Perfil DJ | UserDefaults | Solo nombre de DJ — sin login, sin backend |
| Biblioteca | JSON local en Application Support | Metadatos; audio en disco del DJ |
| Backend cloud | CloudKit o Supabase — **Fase 3** | Sync Mac↔iPad, sets en la nube |
| Suscripciones | RevenueCat + App Store — **Fase 3** | Planes Pro / Pro+ |
| Pool integración | Beatsource API — **Fase 2** | Futura: PromoMusicBcn + pools europeas |

---

## Modelo de negocio

| Plan | Precio | Funcionalidades |
|------|--------|----------------|
| Free | 0€ | Mezcla básica, biblioteca local, 30 días prueba completa |
| Pro | 9,99€/mes | Stems IA, conexión pools, grabación sets, exportar video |
| Pro+ | 19,99€/mes | Todo Pro + analytics avanzados, sets en la nube ilimitados |

Distribución: **App Store** (macOS + iOS) como objetivo final.
Durante desarrollo: distribución directa via TestFlight / notarización macOS.

---

## Features por fases

### Fase 1 — MVP
- [x] Reproductor de 2 decks (cargar canción, play/pause, sync BPM)
- [x] Crossfader y EQ básico (graves, medios, agudos por deck)
- [x] Análisis automático de BPM y key al importar canción
- [x] Biblioteca local de música (JSON en Application Support)
- [x] Perfil DJ local (nombre en UserDefaults — sin login ni backend)
- [ ] Probar en Mac con canciones reales
- [ ] Crear proyecto Xcode (.xcodeproj) para desarrollo con Mauri
- [ ] Invitar a Mauri como collaborator en GitHub

### Fase 2 — IA
- [ ] Stem separation en tiempo real (Core ML + Neural Engine)
- [ ] Sugerencia de siguiente canción por BPM, key y energía
- [ ] Beatgrid automático preciso (incluso en canciones sin tempo constante)
- [ ] Cue points automáticos inteligentes

### Fase 3 — Pools y monetización
- [ ] Integración Beatsource (streaming + descarga)
- [ ] Contacto/integración PromoMusicBcn y pools europeas
- [ ] Grabación de sets (audio + video con visuales IA)
- [ ] Exportación directa a YouTube, Mixcloud, Twitch con tracklist autogenerado
- [ ] Sistema "Legaliza tu mix" (compra con un clic lo que usaste)

### Fase 4 — Pro features
- [ ] Analytics: qué canciones funcionaron, en qué venue, a qué hora
- [ ] Modo colaborativo (dos DJs, mismo set, en remoto)
- [ ] AI Prompt: "hazme un set de salsa de los 90" → playlist automática
- [ ] Visuales generados por IA en tiempo real (para pantallas del venue)

---

## Flujo de trabajo Git (colaboración con Mauri)

```
main          ← rama protegida, solo merge via PR
develop       ← rama de integración
feature/xxx   ← ramas de Mauri o Nelson para cada feature
fix/xxx       ← ramas para bug fixes
```

- Nelson es owner del repo en GitHub (Nelsitobcn/Pulso)
- Mauri trabaja en ramas `feature/` y abre Pull Requests a `develop`
- Nunca push directo a `main`
- Cada PR necesita al menos 1 review antes de mergear

---

## Archivos clave

| Archivo | Propósito |
|---------|-----------|
| `CLAUDE.md` | Este archivo — arquitectura y reglas |
| `LEARNINGS.md` | Bugs encontrados y lecciones aprendidas |
| `.gitignore` | Exclusiones de git |
| `Pulso.xcodeproj` | Proyecto Xcode (cuando se cree) |

---

## Reglas de desarrollo

1. Leer LEARNINGS.md antes de cualquier cambio
2. No subir a `main` directamente — siempre via PR
3. No commitear archivos `.xcuserstate` ni `DerivedData/`
4. Verificar en dispositivo real (Mac + iPad) antes de marcar feature como completa
5. Actualizar LEARNINGS.md tras cada bug resuelto

---

## Contexto de investigación

- NotebookLM: "Software DJ con IA — Estado del Arte 2026" (creado 2026-03-31)
  - 76 fuentes sobre VirtualDJ, Serato, Rekordbox, music pools, IA
  - URL: https://notebooklm.google.com/notebook/8885a4a5-0d13-4b4b-a8f7-f295bcd0dab6
- Competencia principal: VirtualDJ (líder en IA), Serato (líder en clubs), djay Pro (líder en Mac/iOS)
- Gap principal: ninguno es nativo Apple Silicon + ninguno integra pools europeas
