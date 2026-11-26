// Herramienta del administrador. Lo normal es aprobar o rechazar desde la app
// (menú de cuenta > "Panel de verificación"); este script solo hace falta UNA VEZ,
// para nombrar al primer administrador. Usa serviceAccountKey.json (no se sube a GitHub).
//
//   node admin_verificaciones.js admin CORREO        -> hace administrador a esa cuenta
//   node admin_verificaciones.js quitar-admin CORREO
//
// Opcional, por si no tienes el móvil a mano:
//   node admin_verificaciones.js                     -> lista las solicitudes pendientes
//   node admin_verificaciones.js aprobar CORREO
//   node admin_verificaciones.js rechazar CORREO "motivo"
//   node admin_verificaciones.js retirar CORREO "motivo"

const { initializeApp, cert } = require("firebase-admin/app");
const { getAuth } = require("firebase-admin/auth");
const { getFirestore, FieldValue } = require("firebase-admin/firestore");

function iniciar() {
  let serviceAccount;
  try {
    serviceAccount = require("./serviceAccountKey.json");
  } catch {
    console.error("Falta serviceAccountKey.json en esta carpeta (Firebase > Configuración > Cuentas de servicio).");
    process.exit(1);
  }
  initializeApp({ credential: cert(serviceAccount) });
  return { auth: getAuth(), db: getFirestore() };
}

async function buscarUsuario(auth, correo) {
  try {
    return correo.includes("@") ? await auth.getUserByEmail(correo) : await auth.getUser(correo);
  } catch {
    throw new Error(`No existe ninguna cuenta con "${correo}". Regístrate antes en la app.`);
  }
}

async function main() {
  const [accion = "pendientes", correo, extra] = process.argv.slice(2);
  const { auth, db } = iniciar();
  const necesitaCorreo = () => {
    if (!correo) throw new Error(`Falta el correo: node admin_verificaciones.js ${accion} CORREO`);
  };

  switch (accion) {
    case "admin": {
      necesitaCorreo();
      const u = await buscarUsuario(auth, correo);
      await db.collection("admins").doc(u.uid).set({ email: u.email, fecha: FieldValue.serverTimestamp() });
      console.log(`✅ ${u.email} ya es administrador. Abre la app: en el menú de cuenta verás "Panel de verificación".`);
      return;
    }
    case "quitar-admin": {
      necesitaCorreo();
      const u = await buscarUsuario(auth, correo);
      await db.collection("admins").doc(u.uid).delete();
      console.log(`${u.email} ya no es administrador.`);
      return;
    }
    case "pendientes": {
      const snap = await db.collection("solicitudes").where("estado", "==", "pendiente").get();
      if (snap.empty) return console.log("No hay solicitudes pendientes.");
      snap.forEach((d) => {
        const s = d.data();
        console.log(`\n${s.email}\n  ${s.nombre} - ${s.rol} - nº ${s.numeroOficial}`);
      });
      return;
    }
    case "aprobar": {
      necesitaCorreo();
      const u = await buscarUsuario(auth, correo);
      const ref = db.collection("solicitudes").doc(u.uid);
      const s = (await ref.get()).data();
      if (!s) throw new Error(`${u.email} no ha enviado ninguna solicitud.`);
      await db.collection("roles").doc(u.uid).set({
        rol: s.rol, nombre: s.nombre, email: s.email, numeroOficial: s.numeroOficial,
        aprobadoPor: "terminal", fecha: FieldValue.serverTimestamp(),
      });
      await ref.update({ estado: "aprobada", motivo: "", fechaRevision: FieldValue.serverTimestamp() });
      console.log(`✅ ${u.email} verificado como ${s.rol}.`);
      return;
    }
    case "rechazar":
    case "retirar": {
      necesitaCorreo();
      const u = await buscarUsuario(auth, correo);
      if (accion === "retirar") await db.collection("roles").doc(u.uid).delete();
      await db.collection("solicitudes").doc(u.uid).set(
        { estado: accion === "rechazar" ? "rechazada" : "retirada", motivo: extra || "", fechaRevision: FieldValue.serverTimestamp() },
        { merge: true },
      );
      console.log(`Hecho: ${u.email} (${accion}).`);
      return;
    }
    default:
      throw new Error(`Acción desconocida "${accion}". Usa: admin, quitar-admin, pendientes, aprobar, rechazar o retirar.`);
  }
}

main()
  .then(() => process.exit(0))
  .catch((e) => {
    console.error("Error:", e.message);
    process.exit(1);
  });
