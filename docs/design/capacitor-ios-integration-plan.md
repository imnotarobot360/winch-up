# WINCH-UP: integración con Capacitor y Xcode

Este documento prepara una tarea posterior. El PR #8 rediseña la aplicación web; no instala
Capacitor, no crea una aplicación iOS y no cambia el despacho, las reglas de SOS, la aprobación
de voluntarios ni las migraciones de recuperación.

## Punto de partida

La interfaz ya declara `viewport-fit=cover`, utiliza áreas seguras del dispositivo, conserva
el zoom y separa el formulario SOS y las conversaciones de la navegación inferior. Los textos
siguen disponibles en inglés y español. La validación responsive con Playwright es una base
para el trabajo nativo, pero no equivale a pruebas en un iPhone físico.

El repositorio utiliza Next.js App Router, cookies de sesión, Server Actions y rutas dinámicas.
`next build` produce un servidor y sus recursos; `.next` **no** es un `webDir` de Capacitor.
Cambiar a `output: "export"` eliminaría capacidades que las pantallas protegidas necesitan.

Capacitor 8.5.3 es la versión publicada consultada al preparar este plan. Su CLI requiere
Node.js >=22 y el paquete iOS declara iOS 15.0 como mínimo. Deben fijarse conjuntamente
`@capacitor/core`, `@capacitor/cli` y `@capacitor/ios` al iniciar la integración; no depender de
`latest` para builds reproducibles. La versión de Xcode y los plugins elegidos se comprobarán
contra los requisitos de esa versión en el Mac de desarrollo.

## Arquitectura propuesta para distribución

Crear un cliente web empaquetable dentro de `native/`, con recursos estáticos locales y un
`index.html` propio. Reutilizar los componentes de presentación, los tokens de color y los
catálogos del rediseño. Mantener Next.js como servidor web y API; la lógica de recuperación
y sus decisiones de acceso seguirán en las mismas funciones de PostgreSQL.

Antes de escribir el cliente, definir adaptadores de API para las operaciones que ahora son
Server Actions. La aplicación nativa debe poder autenticarse y realizar esas operaciones sin
depender de llamadas internas de Next.js ni de cookies compartidas entre orígenes.

- Verificar la sesión en el servidor y derivar allí la identidad del solicitante y su IP.
- Conservar la autorización existente en cada RPC, la idempotencia y la validación de entrada.
- Utilizar solo las credenciales públicas de Supabase en el cliente. La clave de servicio,
  Twilio y los secretos de despacho seguirán en el servidor.
- Definir explícitamente los orígenes del cliente nativo y las reglas de CORS. No sustituir
  la autorización por CORS ni permitir orígenes arbitrarios.
- Mantener las coordenadas aproximadas del mapa público y la entrega de datos exactos solo
  mediante las rutas autorizadas que ya existen.

Para una prueba interna inicial puede usarse `server.url` con un servidor HTTPS de staging
para comprobar WKWebView, formularios y el puente nativo. Capacitor documenta `server.url`
como una opción de desarrollo, no de producción. Esa prueba no es la arquitectura de
distribución y no se enviará a App Store. Tampoco se activarán HTTP sin cifrar, contenido
mixto ni permisos de navegación generales para hacer que una prueba funcione.

## Etapas de implementación

| Etapa | Trabajo | Condición de aceptación |
| --- | --- | --- |
| 1. Contratos | Inventariar Server Actions, autenticación y rutas usadas por las siete pantallas; definir adaptadores JSON autenticados. | Las mismas pruebas de autorización y recuperación pasan para web y cliente nativo. |
| 2. Cliente local | Crear el paquete `native/`, compartir estilos y textos, añadir Capacitor con versiones fijadas y `webDir: "dist"`. | El shell local arranca sin depender de un servidor de desarrollo. |
| 3. Sesión | Implementar restauración, renovación, cierre de sesión y enlaces de verificación/restablecimiento con las APIs oficiales. | Ninguna sesión ni conversación cambia de usuario al reabrir la app; un token vencido no entrega datos. |
| 4. Dispositivo | Añadir geolocalización, cámara/galería, teclado, estado de conexión y apertura de mapas/enlaces. | Permisos denegados tienen alternativa; cada ubicación se confirma antes de enviar. |
| 5. Recuperación | Conectar SOS, estado, ofertas, equipo y chat a los contratos existentes. | Se conserva el aviso de 911, el consentimiento, la aprobación, el cierre y la idempotencia. |
| 6. Xcode | Compilar en simulador y dispositivo, configurar identificador y firma de desarrollo. | Build Debug reproducible; pruebas reales de teclado, áreas seguras, fotos y GPS documentadas. |
| 7. Distribución | Revisar privacidad, requisitos de Apple, plugins y capacidades antes de una entrega interna. | No hay secretos en el bundle ni configuración de live reload; publicación autorizada por separado. |

## Preparación del Mac y Xcode

Se necesita un Mac con una versión de macOS compatible con el Xcode requerido por Capacitor,
las Command Line Tools, Node.js >=22 y un iPhone para la validación física. Un Apple ID permite
ciertas pruebas locales; TestFlight, distribución y las capacidades correspondientes requieren
el equipo y la inscripción apropiados en Apple Developer. No guardar certificados ni claves
de firma en el repositorio.

En la futura rama de integración, dentro del paquete nativo y después de generar su cliente:

```bash
npm install --save-exact @capacitor/core@8.5.3 @capacitor/ios@8.5.3
npm install --save-dev --save-exact @capacitor/cli@8.5.3
npx cap init
npm run build
npx cap add ios
npx cap sync ios
npx cap open ios
```

`npm run build` en ese bloque pertenece al futuro paquete `native/`, no al servidor Next.js
de la raíz. `cap init` debe usar el identificador de aplicación aprobado y `webDir: "dist"`.
Elegir y fijar el mecanismo de dependencias iOS soportado por Capacitor; abrir el proyecto
generado en Xcode y seleccionar el equipo de desarrollo antes de probar en dispositivo.

En Xcode comprobar Bundle Identifier, Deployment Target, Signing & Capabilities, iconos,
orientaciones y el comportamiento de la barra de estado sobre la interfaz oscura. Las
descripciones de permisos deben explicar su uso: ubicación durante la elección del punto
de recuperación y acceso a fotos/cámara para adjuntar imágenes. No habilitar ubicación en
segundo plano: este diseño no requiere seguimiento continuo.

## Integraciones del dispositivo

- **Ubicación:** solicitarla en el paso correspondiente del SOS. Mantener la alternativa de
  pegar coordenadas cuando se deniegue. Precisión, confirmación del punto y consentimiento
  conservan el mismo significado que en la aplicación web.
- **Fotos:** mantener compresión y eliminación de EXIF antes de subir; pasar por los buckets
  privados y URLs firmadas existentes. La cámara nativa no justifica subir el original.
- **Teclado:** comprobar el redimensionado de WKWebView y el plugin de teclado con el chat.
  Enviar, volver y confirmar deben ser alcanzables con el teclado abierto y en horizontal.
- **Enlaces:** abrir mapas y `tel:911` mediante mecanismos adecuados del dispositivo. Verificar
  que una llamada requiere la interacción del usuario. Usar enlaces universales para URLs de
  recuperación y autenticación cuando se configure el dominio y la asociación de Apple.
- **Red y chat:** conservar el mensaje en cola hasta el acuse del servidor. Recuperar conexión
  y reintentar con el mismo identificador; no dibujar una entrega que el servidor no confirmó.
- **Push:** tratar APNs como una integración posterior explícita. Web Push existente no prueba
  una suscripción nativa. Los tokens, permisos y preferencias deben conectarse sin cambiar los
  criterios de aprobación ni la elegibilidad del despacho.
- **PWA:** evitar registrar el service worker web dentro del shell local hasta definir su
  interacción con las actualizaciones de recursos y la cola offline de Capacitor.

## Matriz de validación nativa

Probar como mínimo un iPhone compacto, uno con notch/Dynamic Island y uno grande; incluir
iPad si se declara soporte. Repetir en Android con pantalla compacta y navegación por gestos.
Registrar modelo, versión de sistema y resultado, separando simulador de dispositivo físico.

Comprobar ambos idiomas, texto ampliado, VoiceOver/TalkBack, foco, zoom, horizontal y zonas
seguras. Ejecutar también: GPS denegado; mapa sin conexión; foto pesada con EXIF; sesión vencida;
reinicio durante un mensaje pendiente; recuperación finalizada mientras el chat está abierto;
enlace de estado sin sesión; solicitante frente a voluntario pendiente/aprobado/bloqueado.

Una release queda pendiente mientras fallen compilación, reglas de privacidad/aprobación,
confirmación de SOS, pruebas de dispositivo o revisión del bundle. Este plan no autoriza
fusionar a `main`, desplegar producción ni publicar en App Store.

## Referencias verificables

- [Capacitor 8.5.3: tipos de configuración y advertencias de `server.url`](https://github.com/ionic-team/capacitor/blob/8.5.3/cli/src/declarations.ts)
- [Paquete iOS 8.5.3 y mínimo de iOS en su podspec](https://www.npmjs.com/package/@capacitor/ios/v/8.5.3)
- [Flujo oficial de instalación de Capacitor](https://capacitorjs.com/docs/getting-started)
- [Configuración y ejecución del proyecto iOS](https://capacitorjs.com/docs/ios)
