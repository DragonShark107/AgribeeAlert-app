const functions = require("firebase-functions");
const admin = require("firebase-admin");
admin.initializeApp();

exports.notificarNuevoAviso = functions.firestore
  .document("avisos/{avisoId}")
  .onCreate(async (snap, context) => {
    const data = snap.data();
    const tipo = data.tipo || "Tratamiento";
    const localidad = data.localidad || "tu zona";

    const message = {
      topic: "avisos_generales",
      notification: {
        title: "⚡ ALERTA FITOSANITARIA",
        body: `Nuevo tratamiento de ${tipo} en ${localidad}.`,
      },
      data: {
        lat: String(data.latitud),
        lng: String(data.longitud),
      },
    };

    try {
      await admin.messaging().send(message);
      console.log("Notificación push enviada con éxito.");
    } catch (error) {
      console.error("Error enviando push:", error);
    }
  });