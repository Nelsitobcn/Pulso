# Spec — ola2-cabina

## ADDED Requirements

### Requirement: VU meters con señal real
El sistema MUST mostrar en los VU meters A/B el nivel RMS real de la señal post-fader de
cada deck, y MUST NOT usar la posición del fader como proxy de nivel.

#### Scenario: Deck sonando en silencio
- **GIVEN** un deck en modo stems reproduciendo con los 4 stems muteados
- **WHEN** el usuario observa el VU meter del deck
- **THEN** el meter MUST mostrar nivel cero (sin segmentos activos)

#### Scenario: Deck con música
- **GIVEN** un deck reproduciendo música con stems activos
- **WHEN** la señal supera el umbral de cada segmento
- **THEN** el meter MUST moverse siguiendo la dinámica de la señal

### Requirement: Limiter en el bus master
El sistema MUST insertar un peak limiter entre la suma de decks y la salida para impedir
clipping al sumar dos decks a volumen alto. Si el AudioUnit no puede instanciarse, el
sistema MUST degradar a conexión directa sin limiter y MUST NOT impedir el arranque.

#### Scenario: Dos decks a tope
- **GIVEN** ambos decks reproduciendo con crossfader al centro y master al máximo
- **WHEN** la suma supera 0 dBFS
- **THEN** la salida MUST quedar limitada sin distorsión audible de clipping digital

### Requirement: Filtro DJ por deck
Cada deck MUST tener un knob FILTER único (−1…+1): valores negativos MUST aplicar low-pass
con cutoff descendente (20 kHz→200 Hz), positivos MUST aplicar high-pass ascendente
(20 Hz→8 kHz) y el centro MUST dejar la señal sin filtrar (bypass).

#### Scenario: Sweep de bajos
- **GIVEN** un deck reproduciendo
- **WHEN** el usuario gira FILTER hacia la izquierda
- **THEN** los agudos MUST atenuarse progresivamente (low-pass) sin afectar al otro deck

### Requirement: Key Shift y Key Sync
Cada deck MUST soportar un desplazamiento de tono en semitonos (−6…+6) independiente del
tempo. El botón KEY SYNC MUST calcular el desplazamiento mínimo (rueda Camelot: +1 paso =
+7 semitonos, módulo 12, camino mínimo) para casar la key del deck con la del otro deck y
aplicarlo al keyShift propio. Si falta la key de alguna pista, la acción MUST ser un no-op.

#### Scenario: Sincronizar key entre decks
- **GIVEN** Deck A con key 1B y Deck B con key 11B, ambos con pista cargada
- **WHEN** el usuario pulsa KEY SYNC en el Deck A
- **THEN** el Deck A MUST aplicar el desplazamiento mínimo en semitonos que lleva 1B a 11B
- **AND** el display de key del Deck A MUST reflejar el shift aplicado

### Requirement: Beat jump
Cada deck MUST permitir saltar ±4 y ±8 beats manteniendo la reproducción, calculando el
salto como beats × 60/BPM en tiempo de archivo, con clamp a [0, duración].

#### Scenario: Salto adelante en reproducción
- **GIVEN** un deck reproduciendo una pista con BPM analizado
- **WHEN** el usuario pulsa "+4"
- **THEN** la posición MUST avanzar exactamente 4 × 60/BPM segundos sin pausa audible

### Requirement: Grabación del set
El sistema MUST permitir grabar la salida master a un archivo WAV en
`~/Music/Pulso Recordings/` con un botón REC, y al parar MUST cerrar el archivo y exponer
su URL. La grabación MUST capturar la mezcla post-limiter (lo que suena).

#### Scenario: Grabar y parar
- **GIVEN** una mezcla sonando
- **WHEN** el usuario pulsa REC, espera 30 s y vuelve a pulsar
- **THEN** MUST existir un WAV de ~30 s reproducible en la carpeta de grabaciones
