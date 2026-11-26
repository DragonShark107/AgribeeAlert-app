// Herramienta del administrador para verificar apicultores y aplicadores.
// Usa la misma clave que el servidor (serviceAccountKey.json, que no se sube a GitHub).
//
//   node admin_verificaciones.js                     -> lista las solicitudes pendientes
//   node admin_verificaciones.js todas               -> lista todas las solicitudes
//   node admin_verificaciones.js aprobar CORREO      -> verifica la cuenta con el rol que pidió
//   node admin_verificaciones.js aprobar CORREO aplicador  -> verifica con otro rol
//   node admin_verificaciones.js rechazar CORREO "motivo"
//   node admin_verificaciones.js retirar CORREO "motivo"   -> quita la verificación
//
// Comprueba el número antes de aprobar:
//   - Código REGA (apicultores): pídele el justificante de su explotación o consúltalo en su comunidad autónoma.
//   - Nº ROPO (aplicadores): https://www.mapa.gob.es/es/agricultura/temas/sanidad-vegetal/ropo/

const { initializeApp, cert } = require("firebase-admin/app");
const { getAuth } = require("firebase-admin/auth");
const { getFirestore, FieldValue } = require("firebase-admin/firestore");

const ROLES = ["apicultor", "aplicador"];

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

async function buscarUsuario(auth, correoOUid) {
  try {
    return correoOUid.includes("@") ? await auth.getUserByEmail(correoOUid) : await auth.getUser(correoOUid);
  } catch {
    throw new Error(`No existe ninguna cuenta con "${correoOUid}".`);
  }
}

async function listar(db, soloPendientes) {
  let consulta = db.collection("solicitudes");
  if (soloPendientes) consulta = consulta.where("estado", "==", "pendiente");
  const snap = await consulta.get();
  if (snap.empty) {
    console.log(soloPendientes ? "No hay solicitudes pendientes." : "No hay solicitudes.");
    return;
  }
  for (const doc of snap.docs) {
    const s = doc.data();
    const fecha = s.fecha ? s.fecha.toDate().toLocaleString("es-ES") : "-";
    console.log(`\n[${s.estado}] ${s.email}`);
    console.log(`  Nombre: ${s.nombre}`);
    console.log(`  Rol pedido: ${s.rol}   Nº oficial: ${s.numeroOficial}`);
    console.log(`  Fecha: ${fecha}`);
    if (s.motivo) console.log(`  Motivo: ${s.motivo}`);
  }
  console.log(`\nTotal: ${snap.size}`);
}

async function aprobar(auth, db, correo, rolForzado) {
  const usuario = await buscarUsuario(auth, correo);
  const ref = db.collection("solicitudes").doc(usuario.uid);
  const solicitud = (await ref.get()).data();
  const rol = rolForzado || (solicitud && solicitud.rol);
  if (!ROLES.includes(rol)) {
    throw new Error(`Indica el rol: node admin_verificaciones.js aprobar ${correo} apicultor|aplicador`);
  }
  // Primero el rol (lo que de verdad comprueban las reglas) y después la
  // solicitud: la app, al ver "aprobada", renueva el token y recoge el rol.
  await auth.setCustomUserClaims(usuario.uid, { ...(usuario.customClaims || {}), rol });
  await ref.set(
    { estado: "aprobada", rol, fechaRevision: FieldValue.serverTimestamp(), motivo: FieldValue.delete() },
    { merge: true },
  );
  console.log(`✅ ${usuario.email} verificado como ${rol}.`);
}

async function cambiarEstado(auth, db, correo, estado, motivo) {
  const usuario = await buscarUsuario(auth, correo);
  if (estado === "retirada") {
    const { rol, ...resto } = usuario.customClaims || {};
    await auth.setCustomUserClaims(usuario.uid, resto);
    // Cierra sus sesiones para que pierda el permiso enseguida (no al cabo de una hora).
    await auth.revokeRefreshTokens(usuario.uid);
  }
  await db.collection("solicitudes").doc(usuario.uid).set(
    { estado, motivo: motivo || "", fechaRevision: FieldValue.serverTimestamp() },
    { merge: true },
  );
  console.log(`${estado === "retirada" ? "⛔ Verificación retirada a" : "❌ Solicitud rechazada:"} ${usuario.email}.`);
}

async function main() {
  const [accion = "pendientes", correo, extra] = process.argv.slice(2);
  const { auth, db } = iniciar();

  switch (accion) {
    case "pendientes":
      return listar(db, true);
    case "todas":
      return listar(db, false);
    case "aprobar":
      if (!correo) throw new Error("Uso: node admin_verificaciones.js aprobar CORREO [apicultor|aplicador]");
      return aprobar(auth, db, correo, extra);
    case "rechazar":
    case "retirar":
      if (!correo) throw new Error(`Uso: node admin_verificaciones.js ${accion} CORREO "motivo"`);
      return cambiarEstado(auth, db, correo, accion === "rechazar" ? "rechazada" : "retirada", extra);
    default:
      throw new Error(`Acción desconocida "${accion}". Usa: pendientes, todas, aprobar, rechazar o retirar.`);
  }
}

main()
  .then(() => process.exit(0))
  .catch((e) => {
    console.error("Error:", e.message);
    process.exit(1);
  });
