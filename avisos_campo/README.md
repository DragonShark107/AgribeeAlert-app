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

El administrador revisa las solicitudes con `admin_verificaciones.js`, que usa el mismo `serviceAccountKey.json`:

```
node admin_verificaciones.js                          # pendientes
node admin_verificaciones.js aprobar correo@ejemplo.es
node admin_verificaciones.js rechazar correo@ejemplo.es "motivo"
node admin_verificaciones.js retirar correo@ejemplo.es "motivo"
```
