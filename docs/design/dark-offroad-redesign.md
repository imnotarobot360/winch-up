# Rediseño oscuro off-road

El PR #8 empezó con clases visuales sin conectar a las pantallas. El rediseño integra un
sistema de cabeceras, tarjetas, acciones, estados y navegación con fondo oscuro, verde
forestal y naranja. Las pantallas conservan sus datos, autorización y operaciones existentes.

| Pantalla | Cambios de presentación |
| --- | --- |
| Inicio `/` | Panel de marca para visitantes; mapa y acciones SOS/ayuda para miembros, con disposición móvil y dos columnas en escritorio. El contador refleja solicitudes abiertas del tablero. |
| SOS `/request` | Cabecera por paso, foco en la nueva pregunta, controles amplios y acciones inferiores con área segura. Continúan los ocho pasos, el aviso de 911 y las confirmaciones. |
| Mapa `/board` | Vista de mapa inicial, controles mapa/lista y filtros, tarjetas responsive y estado claro cuando el mapa no está disponible. Se mantienen las coordenadas aproximadas. |
| Seguimiento `/r/[token]` | Código de recuperación visible, jerarquía de estado y voluntario, timeline conectado y acciones de llamada, mapa y cierre. |
| Chat `/messages` y recuperación | Cabeceras y burbujas coherentes, texto largo que se ajusta y compositor accesible. La conversación privada tiene su propio retorno y espacio para el teclado. |
| Perfil `/me`, ajustes `/account` | Cabecera con identidad, acciones de recuperación y tarjetas; los ajustes mantienen activo el destino Perfil en la barra inferior. |
| Navegación | Cinco destinos existentes, SOS destacado, etiquetas de una línea, foco visible y áreas seguras. Mensajes tiene entrada directa en la cabecera. |

Los colores semánticos siguen definidos en `src/app/globals.css`. Los estilos `winch-*`
utilizan esos tokens; `ScreenHeading` comparte la cabecera sin añadir decisiones de acceso.
`Card` aplica la misma superficie a los paneles existentes. Los textos de la aplicación siguen
en los catálogos de inglés y español.

## Límites de la integración

La base del PR es `bc879ec`, que ya contiene la decisión previa de revertir parte de Recovery
V2 y conservar la aprobación. Este rediseño mantiene ese estado: las Server Actions, los RPC,
las migraciones y las bibliotecas de validación no forman parte del cambio.

La interfaz tampoco fabrica voluntarios, posiciones ni estados. El mapa público recibe los
mismos datos aproximados de `board_requests`; los detalles exactos y el chat siguen sujetos
a sus permisos existentes. Un mensaje en cola conserva su aspecto pendiente hasta el acuse
del servidor. El contador de inicio evita presentar solicitudes cerradas como abiertas o
afirmar proximidad sin haber consultado la ubicación del lector.

## Cómo comprobarlo

Desde la raíz, con Node >=22 y npm 11:

```bash
npm ci
npm run verify
```

Preparar una base **local** según README y `scripts/local-stack/README.md`, con todas las
migraciones, la semilla de referencia, `mark-local.sql` y la semilla demo. Configurar
`.env.local` con las claves locales y `SMS_DRY_RUN=1`. Las pruebas usan cuentas demo y no
deben apuntar a producción.

```bash
npm run test:e2e
```

La nueva suite `e2e/dark-offroad-responsive.spec.ts` comprueba la navegación en ambos idiomas
a 320, 390, 412, 844 y 1.440 píxeles; las pantallas de miembros; la puerta de emergencia y
el requisito de ubicación del SOS; una conversación real con texto largo y menor espacio de
pantalla; y el seguimiento compartido sin mostrar el compositor privado. Genera capturas en
`test-results/`, que sigue siendo un directorio ignorado por Git.

Los proyectos Playwright cubren Chromium para Android/escritorio y WebKit para iPhone/tablet.
Sus emulaciones no prueban un teclado físico de iOS, sensores, cámara ni un build de Xcode.
El mapa con tiles requiere un token Mapbox válido; comprobar el estado de fallback no prueba
la selección de un punto en el mapa real. La alternativa local del repositorio tampoco
implementa Supabase Storage, por lo que las subidas necesitan validación con la pila completa.

El plan de la siguiente etapa está en
[Integración con Capacitor y Xcode](capacitor-ios-integration-plan.md).

## Resultados de esta revisión — 9 de octubre de 2026 (UTC)

| Comprobación | Resultado |
| --- | --- |
| `npm run verify` | TypeScript, lint, 240 pruebas unitarias, catálogos EN/ES y build de 106 rutas correctos. |
| PostgreSQL 17 + PostGIS + pgTAP | 43 suites, 1.430 aserciones; ninguna fallida o abortada. |
| Suite E2E completa | 248 pruebas correctas, 88 omitidas, cero fallos y cero resultados intermitentes. |
| Responsive del rediseño | 20 pruebas correctas entre Android, iPhone, tablet y escritorio. |
| axe-core 4.11, WCAG A/AA | Nueve vistas revisadas sin infracciones automáticas detectadas. Los fondos con gradientes dejaron comprobaciones de contraste indeterminadas; no es una certificación de accesibilidad. |

Las 88 omisiones incluyen escenarios con estado ejecutados solo en Android para no duplicar
operaciones entre proyectos y pruebas de avatar que necesitan Storage. La parte de selección
sobre tiles Mapbox también se omitió dentro de su escenario por falta de token. No se añadieron
omisiones al rediseño para ocultar fallos. El contraste calculado de los tokens de texto contra
el extremo más claro del fondo (`#153c29`) es 4,60:1 para texto tenue, 6,90:1 para secundario y
11,19:1 para principal; el texto de las acciones mantiene 5,03:1 incluso en el naranja de hover.
Esto no comprueba cada combinación de contenido y superposición.

La revisión utilizó el fallback local documentado: SQL y RLS reales, Auth local y Storage no
implementado. Quedan pendientes tiles/geocodificación con Mapbox, fotos con Storage, revisión
manual con lector de pantalla y dispositivos físicos. Antes de integrar a `main`, repetir las
comprobaciones en CI y validar esas integraciones en staging. No se desplegó a producción.
