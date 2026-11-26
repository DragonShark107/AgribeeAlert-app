# Agribee Alert (avisos_campo)

App Flutter + Firebase que avisa a apicultores, agricultores y vecinos de los tratamientos fitosanitarios cercanos.

## Ejecutar la app

1. Copia `claves.example.json` a `claves.json` y pon tu clave de Stadia Maps. `claves.json` no se sube a GitHub.
2. Ejecuta:

   ```
   flutter pub get
   flutter run --dart-define-from-file=claves.json
   ```

   En VS Code, F5 ya pasa ese archivo (`.vscode/launch.json`). Sin clave, el mapa oscuro usa CARTO.

## Envío de avisos

Los avisos los reparte el servidor, que calcula a quién le pilla cerca. Usa solo una de estas dos opciones:

- `node servidor_avisos.js`, que necesita `serviceAccountKey.json`. Ese archivo no se sube nunca.
- La Cloud Function de `functions/`, que necesita el plan Blaze: `firebase deploy --only functions`.

Las reglas de seguridad están en `firestore.rules`.

## Verificación de apicultores y aplicadores

- Los vecinos entran directamente.
- Apicultores y aplicadores envían al registrarse su código REGA o su nº ROPO. Hasta que se aprueba, usan la app como vecinos.
- Solo los aplicadores verificados pueden publicar avisos. Lo comprueban las reglas de Firestore, no la app.

Las solicitudes se aprueban o rechazan **desde la app**: menú de cuenta → **Panel de verificación**, que solo ven los administradores. Con el servidor en marcha:
- al administrador le llega una notificación con cada solicitud nueva;
- al usuario le llega otra cuando se aprueba o rechaza la suya.

Para nombrar al primer administrador, solo una vez:

```
node admin_verificaciones.js admin correo@ejemplo.es
```
