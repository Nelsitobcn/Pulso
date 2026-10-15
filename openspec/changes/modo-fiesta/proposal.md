# Modo fiesta — el iPad pincha solo y los invitados piden y votan desde el móvil

## Por qué

Nelson quiere usar Pulso en la fiesta de Navidad en casa de Antonio (petición del 15-oct-2026,
probado a primeros de diciembre). Decisiones ya tomadas:

- El **iPad** es el equipo que suena. El **Mac Studio se queda en casa**: baja las canciones de
  YouTube con yt-dlp, mide su volumen y se las pasa al iPad por **Tailscale**.
- Los invitados piden y votan desde su móvil en una **página web que va por internet**, no por la
  wifi de Antonio (muchas wifis aíslan los móviles entre sí).
- El iPad lleva una **lista de Navidad ya descargada**: si falla internet o el Mac, la música sigue.

El estudio de la competencia (`SecondBrain/Proyectos/Pulso/2026-10-15_estudio-software-dj.md`)
ordena las prioridades: cola con mezcla automática → volumen igualado → lista de Navidad en el
iPad → página de peticiones servida desde el Mac Studio. Ningún programa del mercado junta las
cuatro cosas en un iPad; el plan B es djay en el iPad sin peticiones.

## Qué cambia

1. **Cola de fiesta + mezcla automática (iPad y Mac).** Un `PartyQueue` con «suena», «siguientes
   fijados» (2) y «pendientes». Un `AutomixController` que, al llegar al punto de mezcla, carga el
   siguiente en el deck libre, iguala tempo (si la diferencia es ≤ 6 %, con el SYNC arreglado en
   PR #6), cruza en 8 compases con cambio de graves y libera el deck saliente.
2. **Volumen igualado.** Cada tema lleva una ganancia medida (EBU R128 con ffmpeg en el Mac) que el
   deck aplica al cargar, con tope para no saturar.
3. **Biblioteca de fiesta en el iPad.** Carpeta propia dentro de la app. Botón «Preparar fiesta»
   que copia del Mac Studio, por Tailscale (HTTPS solo dentro de la red privada), la lista de
   Navidad con sus metadatos (BPM, tonalidad, ganancia).
4. **Servidor de fiesta en el Mac Studio** (`fiesta-server/`, Python sin dependencias + SQLite):
   - API privada para el iPad (solo por Tailscale): cola, archivos, «ya ha sonado», veto.
   - Página pública para los móviles, publicada con un **túnel rápido de Cloudflare**: dirección
     aleatoria `*.trycloudflare.com` que deja de existir al apagar el túnel.
5. **Página de peticiones y votos** (sin instalar nada, por QR): lista de Navidad con buscador,
   botones «pedir» y «votar», y qué suena ahora. Reglas anti-abuso.
6. **Pantalla de fiesta en el iPad**: qué suena, qué viene, QR de la página, y botones de rescate
   (pausar la IA, saltar, siguiente ya, vetar).
7. **Modo seguro**: si el Mac o internet no responden, el iPad sigue con su cola y, si se vacía,
   elige solo de la lista local con las reglas del DJ IA (BPM, Camelot, energía), sin Ollama.
8. **iPad preparado para una noche entera**: audio en segundo plano, pantalla siempre encendida.

## Privacidad (regla dura)

- La página pública solo dice «Fiesta de Navidad». **Ni el nombre de Nelson ni PsicoPro** en
  textos, títulos, metadatos ni direcciones.
- **No se usa Tailscale Funnel**: su dirección pública sería `macstudio-de-nelson.<tailnet>.ts.net`
  y lleva el nombre de Nelson.
- Sin cuentas, sin analítica, sin cookies de terceros. Cada móvil lleva un identificador aleatorio
  local. Apodo opcional (máx. 20 caracteres).
- Al terminar la fiesta, `fiesta-server stop` apaga el túnel (la dirección muere) y borra la base
  de datos de peticiones.

## Qué NO cambia

- La mezcla manual: decks, SYNC, EQ, loop y DJ IA siguen igual. El modo fiesta es un modo aparte
  que se activa y se desactiva.
- El trabajo de stems (`feat/stems-ola1`) no entra en este cambio.

## Fuera de alcance (fase 2, solo si sobra tiempo)

- Peticiones libres de cualquier canción de YouTube (requieren descarga en el Mac + aprobación).
- Stems en el iPad, streaming de Spotify/Apple Music, modelo de lenguaje en el iPad.
- Detección inteligente de intro/outro más allá de silencio y energía.

## Fechas

| Cuándo | Hito | Cómo se sabe que está |
|---|---|---|
| 19–25 oct | Pulso compila y suena en el iPad | Dos temas y crossfader, con captura del iPad |
| 26 oct–8 nov | Cola + automix + volumen | Una hora sonando sola en el iPad sin tocar nada, grabada |
| 9–22 nov | Lista de Navidad en el iPad + servidor + modo seguro | Se corta la wifi del iPad y la música sigue |
| 23 nov–1 dic | Página de peticiones, QR, pantalla de fiesta | 3–4 móviles de la familia piden y votan |
| 2–7 dic | Ensayo general de 2 horas | Lista de comprobación completa |
| Si no está fiable el 7-dic | Plan B: djay en el iPad con la lista local | — |
