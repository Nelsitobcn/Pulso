# Diseño — modo-fiesta

## Piezas y por dónde viaja cada cosa

```
Móviles invitados ──internet──► trycloudflare.com (dirección aleatoria)
                                   │ túnel cloudflared (sale del Mac, no abre puertos)
                                   ▼
Mac Studio (casa)   fiesta-server  127.0.0.1:8787  página + API invitados
                                   127.0.0.1:8788  API DJ (clave)  ◄── tailscale serve (HTTPS, solo tailnet)
                    yt-dlp + ffmpeg → ~/Music/Pulso Fiesta/*.m4a + medidas
                                                                     │ Tailscale
                                                                     ▼
iPad (casa de Antonio)  Pulso iOS: PartyQueue + AutomixController + biblioteca local de fiesta
                        sondea /dj/queue cada 5 s; descarga /dj/files; avisa /dj/played
```

## Decisiones (comprobadas el 15-oct-2026)

| Decisión | Por qué | Comprobación |
|---|---|---|
| Servidor en el Mac Studio, no en el iPad | iOS duerme los servidores en segundo plano; muchas wifis aíslan los móviles | — |
| Página por túnel rápido de Cloudflare | Dirección aleatoria que muere al cerrar el túnel; no abre puertos del router | `cloudflared 2026.3.0` instalado en el Mac |
| **No** Tailscale Funnel | Su dirección pública es `macstudio-de-nelson.<tailnet>.ts.net`: lleva el nombre de Nelson | `tailscale funnel status`. El Tailscale del Mac es el de código abierto (Homebrew 1.94.1), así que Funnel sería posible, pero se descarta por privacidad |
| API del DJ por `tailscale serve` | HTTPS con certificado válido (iOS lo exige) y solo dentro de la red privada | Ya hay `serve` activos en el Mac (`/`→:3000, :8443→:4020) |
| Mac → iPad por Tailscale | El iPad responde: `tailscale ping 100.101.75.13` → 7 ms en casa | Fuera de casa irá por relé si no hay conexión directa: medir en el ensayo |
| Medir volumen en el Mac con ffmpeg | Medida estándar (EBU R128) y el Mac ya descarga los temas | ffmpeg instalado |
| Python sin dependencias + SQLite | Arranca con launchd, sin instalar nada, fácil de probar | python3 de Homebrew |
| Catálogo cerrado (lista de Navidad) | Las peticiones libres de YouTube tardan ~25 s y pueden fallar | Medido en el E2E del 11-jul |
| DJ IA por reglas en el modo seguro | Ollama vive en el Mac; en la fiesta no se puede depender de él | Reglas BPM/Camelot ya existen (`DJAssistantService`) |
| Pantalla de fiesta propia en iPad | La ventana actual mide ≥ 1107 pt de alto y no cabe en el iPad | E2E 15-oct (LEARNINGS) |

## Riesgos abiertos

- Velocidad y estabilidad de la conexión Tailscale desde la wifi de Antonio: medir en el ensayo.
- Límites del túnel rápido de Cloudflare (sin garantías de servicio): si falla, la fiesta sigue
  sin peticiones; el iPad no depende de él.
- No consta que Pulso se haya ejecutado en el iPad real (tarea c4ff73d1 abierta): es la tarea 0.1 y bloquea todo lo demás.
- El 15-oct por la mañana el iPad estaba haciendo de pantalla del Mac («iPad NelDesk»): para las pruebas hay que
  liberarlo de esa función.
