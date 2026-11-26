// Cloud Function: avisa a los usuarios cercanos cuando se crea un aviso.
// Hace lo mismo que servidor_avisos.js. Usa solo UNA de las dos opciones:
// si están las dos en marcha a la vez, cada aviso se envía dos veces.
const { onDocumentCreated } = require("firebase-functions/v2/firestore");
const { initializeApp } = require("firebase-admin/app");
const { getFirestore, FieldValue } = require("firebase-admin/firestore");
const { getMessaging } = require("firebase-admin/messaging");
const { notificarAviso } = require("./notificar");

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
