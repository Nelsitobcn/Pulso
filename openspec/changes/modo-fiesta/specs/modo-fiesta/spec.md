# Spec — modo-fiesta

## ADDED Requirements

### Requirement: Cola de fiesta
El sistema MUST mantener una cola de fiesta con tres zonas: el tema que suena, los siguientes
fijados (2 temas) y los pendientes. Los temas fijados MUST NOT cambiar de orden por votos ni
peticiones. Los pendientes MUST ordenarse por número de votos (de mayor a menor) y, a igualdad,
por hora de la primera petición. Un tema que ya ha sonado MUST NOT volver a la cola hasta que
pasen 60 minutos.

#### Scenario: Un pendiente con más votos adelanta
- **GIVEN** una cola con «suena» X, fijados Y y Z, y pendientes P1 (1 voto) y P2 (3 votos)
- **WHEN** el iPad pide la cola al servidor
- **THEN** el orden MUST ser X, Y, Z, P2, P1

#### Scenario: Los fijados no se mueven
- **GIVEN** fijados Y y Z y un pendiente P con 10 votos
- **WHEN** termina X
- **THEN** MUST sonar Y, Z pasa a primer fijado y P pasa a segundo fijado

### Requirement: Mezcla automática
Con el modo fiesta activo, el sistema MUST mezclar solo de un tema al siguiente. El punto de
mezcla MUST ser el primero de: el final útil del tema (último instante con nivel por encima de
−30 dBFS respecto a su máximo) menos la duración del cruce, o la duración total menos la
duración del cruce. El cruce MUST durar 8 compases según el BPM del tema saliente, entre 8 y
24 segundos. Si la diferencia de BPM es de 6 % o menos, el sistema MUST igualar tempo y fase con
el SYNC; si es mayor, MUST hacer un cruce corto de 4 segundos sin cambiar el tempo. Durante el
cruce el sistema MUST mantener los graves del tema entrante cortados hasta la mitad del cruce y
cortar los del saliente a partir de ese momento. Al terminar el cruce, el deck saliente MUST
pararse y volver a tempo 1,0.

#### Scenario: Dos temas de tempo parecido
- **GIVEN** suena un tema a 124 BPM y el siguiente fijado va a 120 BPM
- **WHEN** se llega al punto de mezcla
- **THEN** el siguiente MUST arrancar en el deck libre, sincronizado en fase, y el crossfader
  MUST recorrer de un deck al otro en 8 compases (≈15,5 s)

#### Scenario: Dos temas de tempo muy distinto
- **GIVEN** suena un tema a 96 BPM y el siguiente va a 124 BPM (29 % de diferencia)
- **WHEN** se llega al punto de mezcla
- **THEN** el sistema MUST NOT cambiar el tempo del entrante y MUST cruzar en 4 segundos

#### Scenario: El DJ toma el mando
- **GIVEN** el modo fiesta activo
- **WHEN** el anfitrión pulsa «Pausar IA»
- **THEN** el sistema MUST NOT iniciar ninguna mezcla automática hasta que se pulse «Reanudar IA»,
  y la mezcla manual MUST seguir funcionando

### Requirement: Volumen igualado
Cada tema de la biblioteca de fiesta MUST llevar una ganancia calculada a partir de su sonoridad
integrada (EBU R128) para llevarlo a −14 LUFS. La ganancia MUST limitarse a [−12, +6] dB y
MUST reducirse lo necesario para que el pico real más la ganancia no supere −1 dBTP. El deck
MUST aplicar esa ganancia al cargar el tema. Un tema sin medir MUST sonar con ganancia 0 dB.

#### Scenario: Tema de YouTube muy alto
- **GIVEN** un tema medido a −7 LUFS con pico real de −0,1 dBTP
- **WHEN** se carga en un deck
- **THEN** el deck MUST aplicar −7 dB

#### Scenario: Tema muy bajo con picos altos
- **GIVEN** un tema medido a −22 LUFS con pico real de −3 dBTP
- **WHEN** se calcula su ganancia
- **THEN** la ganancia MUST ser +2 dB (limitada por el pico), no +8 dB

### Requirement: Biblioteca de fiesta en el iPad
El iPad MUST guardar los temas de la fiesta dentro de la propia app, con su BPM, tonalidad,
ganancia y final útil, y MUST poder reproducirlos sin red. La acción «Preparar fiesta» MUST
descargar del Mac Studio, por la red privada de Tailscale, los temas que falten, mostrar el
progreso y el espacio libre, y MUST NOT borrar los ya descargados si se corta a medias.

#### Scenario: Sin internet en la fiesta
- **GIVEN** la lista de Navidad ya preparada en el iPad
- **WHEN** el iPad pierde la wifi
- **THEN** la música MUST seguir sonando y la cola MUST seguir avanzando

### Requirement: Modo seguro
Si el iPad no recibe respuesta del servidor durante 30 segundos, MUST seguir con los temas que
ya tiene en cola y MUST mostrar un aviso discreto «Sin conexión: el DJ sigue solo». Si la cola se
queda sin temas, el sistema MUST elegir el siguiente de la biblioteca de fiesta con las reglas del
DJ IA (BPM compatible, tonalidad Camelot compatible, energía) sin usar Ollama ni internet, y MUST
NOT repetir un tema sonado en los últimos 60 minutos. La pista MUST NOT quedarse en silencio.

#### Scenario: Se cae el Mac Studio
- **GIVEN** suena un tema y no hay más en cola
- **WHEN** el servidor deja de responder
- **THEN** al llegar al punto de mezcla el iPad MUST elegir solo el siguiente tema de su
  biblioteca y mezclarlo

### Requirement: Servidor de fiesta separado en dos puertas
El servidor del Mac Studio MUST escuchar solo en 127.0.0.1, en dos puertos distintos: uno
público (página y API de invitados) y uno privado (API del DJ). El puerto público MUST salir a
internet solo por un túnel rápido de Cloudflare con dirección aleatoria. El puerto privado MUST
salir solo por `tailscale serve` (HTTPS dentro de la red privada) y MUST exigir una clave del DJ.
Ninguna ruta del DJ MUST responder en el puerto público.

#### Scenario: Un invitado prueba la API del DJ
- **GIVEN** la dirección pública de la fiesta
- **WHEN** alguien pide `/dj/queue` en esa dirección
- **THEN** el servidor MUST responder 404

#### Scenario: Fin de fiesta
- **GIVEN** el servidor y el túnel en marcha
- **WHEN** se ejecuta `fiesta-server stop`
- **THEN** el túnel MUST cerrarse (la dirección deja de existir) y la base de datos de peticiones
  y votos MUST borrarse

### Requirement: Página de peticiones y votos
La página pública MUST funcionar en el navegador del móvil sin instalar nada ni registrarse.
MUST mostrar qué suena, los siguientes y la lista de Navidad con buscador, y permitir «pedir» y
«votar». Reglas: un móvil MUST NOT pedir más de un tema cada 5 minutos; MUST NOT votar dos veces
el mismo tema; MUST NOT pedir un tema que ya está en cola (se convierte en voto) ni uno sonado en
los últimos 60 minutos. Un tema vetado por el anfitrión MUST desaparecer de la lista de la noche.

#### Scenario: Petición repetida
- **GIVEN** el tema T ya está en pendientes
- **WHEN** un invitado pulsa «pedir» en T
- **THEN** el sistema MUST sumar un voto a T y MUST NOT duplicarlo en la cola

#### Scenario: Demasiadas peticiones
- **GIVEN** un móvil que pidió un tema hace 2 minutos
- **WHEN** pide otro
- **THEN** la página MUST decir cuántos minutos faltan y MUST NOT añadirlo

### Requirement: Privacidad de la página pública
La página pública MUST NOT contener el nombre de Nelson, el de PsicoPro ni ningún dato que
permita identificar al anfitrión: ni en textos, títulos, metadatos, direcciones ni respuestas de
la API. El título MUST ser «Fiesta de Navidad». El sistema MUST NOT usar Tailscale Funnel (su
dirección incluye el nombre del equipo). MUST NOT usar analítica ni recursos de terceros en la
página. El identificador de cada móvil MUST ser aleatorio y local; el apodo es opcional (máx. 20
caracteres) y MUST borrarse al acabar la fiesta.

#### Scenario: Revisión de la página antes de la fiesta
- **GIVEN** la página pública servida
- **WHEN** se descarga el HTML y todas las respuestas de la API y se buscan «nelson», «nelsito»,
  «psicopro», «ordóñez» y «ordonez» sin distinguir mayúsculas
- **THEN** no MUST aparecer ninguna coincidencia

### Requirement: Pantalla de fiesta en el iPad
Con el modo fiesta activo, el iPad MUST mostrar a pantalla completa qué suena, los dos siguientes,
el apodo de quien lo pidió (si lo hay), el QR de la página pública y los botones de rescate:
«Pausar IA / Reanudar IA», «Saltar», «Siguiente ya» y «Vetar». La pantalla MUST NOT apagarse
sola y el audio MUST seguir con la app en segundo plano o con la pantalla bloqueada. Todos los
botones MUST tener etiqueta de accesibilidad en español que diga su acción.

#### Scenario: Vetar desde el iPad
- **GIVEN** un tema pendiente que el anfitrión no quiere
- **WHEN** pulsa «Vetar» sobre él
- **THEN** el tema MUST salir de la cola y MUST NOT poder pedirse otra vez esa noche
