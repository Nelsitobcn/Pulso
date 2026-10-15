# Tasks — modo-fiesta

## 0. Base en el iPad (19–25 oct)
- [ ] 0.1 Instalar Pulso (Debug, equipo R2FJ7AYYTH) en el iPad Pro 12,9" (6.ª gen) y
      comprobar que suena: dos temas, play, crossfader. Captura del iPad.
- [ ] 0.2 `Info.plist` iOS: `UIBackgroundModes = audio`; `AVAudioSession` categoría `.playback`;
      `isIdleTimerDisabled = true` mientras el modo fiesta esté activo.
- [ ] 0.3 Probar 30 min con la pantalla bloqueada: el audio no se corta.

## 1. Motor: cola + mezcla automática (26 oct–8 nov)
- [ ] 1.1 `PartyQueue` (modelo puro, Swift): suena / fijados(2) / pendientes; orden por votos
      y hora; bloqueo de 60 min para lo ya sonado. Tests unitarios de los escenarios del spec.
- [ ] 1.2 `Track`: campos `gainDb: Double?` y `usefulEnd: Double?` (opcionales, Codable
      compatible con la biblioteca actual).
- [ ] 1.3 Ganancia por deck en `AudioEngine.load`: aplicar `gainDb` (0 si falta) en un nodo de
      ganancia propio, sin tocar el fader del DJ.
- [ ] 1.4 `AutomixController`: punto de mezcla, cruce de 8 compases (8–24 s) o 4 s si ΔBPM > 6 %,
      SYNC si ΔBPM ≤ 6 %, graves cruzados a mitad, parar y resetear el saliente.
- [ ] 1.5 Botones de rescate: Pausar/Reanudar IA, Saltar, Siguiente ya.
- [ ] 1.6 Prueba: una hora de lista sonando sola en el iPad sin tocar nada; grabación y captura
      de la cola al final.

## 2. Mac Studio: servidor + preparación de la lista (9–22 nov)
- [ ] 2.1 `fiesta-server/` (Python 3 sin dependencias + SQLite): `start` / `stop`;
      puerto público 127.0.0.1:8787, puerto DJ 127.0.0.1:8788.
- [ ] 2.2 `fiesta-server add <url|búsqueda>`: yt-dlp (argumentos como lista) → m4a en
      `~/Music/Pulso Fiesta/`, medición `ffmpeg ebur128` (LUFS integrado + pico real) y final
      útil; ganancia según el spec.
- [ ] 2.3 API DJ (clave en el Llavero del iPad): `GET /dj/catalog`, `GET /dj/queue`,
      `GET /dj/files/<id>.m4a`, `POST /dj/played`, `POST /dj/veto`, `GET /dj/info` (URL pública).
- [ ] 2.4 `tailscale serve` para el puerto DJ (HTTPS solo tailnet). Comprobar que no choca con
      los `serve` existentes (`/` → :3000 y :8443 → :4020).
- [ ] 2.5 iPad: «Preparar fiesta» descarga lo que falte, con progreso y espacio libre;
      reanudable.
- [ ] 2.6 Modo seguro: 30 s sin servidor → aviso y DJ IA por reglas sobre la biblioteca local.
- [ ] 2.7 Prueba: cortar la wifi del iPad en mitad de un tema; la música sigue y la cola avanza.

## 3. Invitados: página, QR y pantalla de fiesta (23 nov–1 dic)
- [ ] 3.1 Página pública (HTML + JS propio, sin recursos externos): suena / siguientes /
      lista con buscador / pedir / votar / apodo opcional. Título «Fiesta de Navidad».
- [ ] 3.2 Reglas anti-abuso del spec (5 min por móvil, 1 voto por tema, petición repetida =
      voto, 60 min sin repetir, vetados fuera).
- [ ] 3.3 `fiesta-server start` lanza `cloudflared tunnel --url http://127.0.0.1:8787`, lee la
      dirección `*.trycloudflare.com` y la expone en `/dj/info`. `stop` cierra el túnel y borra
      la base de datos.
- [ ] 3.4 Pantalla de fiesta iPad: suena / 2 siguientes / apodo / QR (CoreImage) / rescate +
      Vetar. Etiquetas de accesibilidad en español.
- [ ] 3.5 Prueba de privacidad del spec (buscar nombres en HTML y API): 0 coincidencias.
- [ ] 3.6 Prueba con 3–4 móviles reales desde datos móviles (no la wifi de casa).

## 4. Lista de Navidad y ensayo (2–7 dic)
- [ ] 4.1 Lista de 100–150 temas acordada con Nelson y Antonio; añadida con `fiesta-server add`.
- [ ] 4.2 Ensayo general de 2 horas con lista de comprobación: peticiones, votos, veto, corte
      de internet, corte del Mac, volumen igualado, rescate manual, batería/enchufe del iPad.
- [ ] 4.3 Si algo crítico falla el 7-dic: plan B (djay en el iPad con la lista local).
