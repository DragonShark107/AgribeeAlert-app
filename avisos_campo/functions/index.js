// Cloud Function: avisa a los usuarios cercanos cuando se crea un aviso.
// Hace lo mismo que servidor_avisos.js. Usa solo UNA de las dos opciones:
// si están las dos en marcha a la vez, cada aviso se envía dos veces.
const { onDocumentCreated, onDocumentWritten } = require("firebase-functions/v2/firestore");
const { initializeApp } = require("firebase-admin/app");
const { getFirestore, FieldValue } = require("firebase-admin/firestore");
const { getMessaging } = require("firebase-admin/messaging");
const { notificarAviso, notificarSolicitud } = require("./notificar");

initializeApp();

exports.notificarNuevoAviso = onDocumentCreated("avisos/{avisoId}", async (event) => {
  const snap = event.data;
  if (!snap) return;

  try {
    const r = await notificarAviso({
      db: getFirestore(),
      messaging: getMessaging(),
      FieldValue,
      avisoId: event.params.avisoId,
      aviso: snap.data(),
    });
    console.log(`Aviso ${event.params.avisoId}: ${r.usuarios} usuarios afectados, ${r.enviados} enviados, ${r.fallidos} fallidos.`);
  } catch (error) {
    console.error("Error enviando aviso:", error);
  }
});

// Solicitudes de verificación: avisa a los administradores de las nuevas y al
// usuario cuando se aprueba, rechaza o retira la suya.
exports.notificarSolicitud = onDocumentWritten("solicitudes/{uid}", async (event) => {
  try {
    await notificarSolicitud({
      db: getFirestore(),
      messaging: getMessaging(),
      FieldValue,
      uid: event.params.uid,
      antes: event.data?.before?.data(),
      despues: event.data?.after?.data(),
    });
  } catch (error) {
    console.error("Error notificando solicitud:", error);
  }
});
