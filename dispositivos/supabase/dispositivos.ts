// Función de borde «dispositivos» (Supabase Edge Function, sin verificación de JWT).
//
// Es la puerta de la web del Registro de dispositivos: recibe {clave, accion, args}, llama a
// public.rd_accion (que comprueba la clave) con la clave de servicio —que vive solo en el entorno de la
// función, nunca en la web— y devuelve el JSON tal cual. Todo el trabajo y todas las comprobaciones
// están en SQL (sql/001_registro_dispositivos.sql); aquí solo se valida la forma de la petición.
//
// Despliegue: sin verificación de JWT (la web no tiene sesión de Supabase; el acceso lo da la clave).
//   supabase functions deploy dispositivos --no-verify-jwt
import { createClient } from "npm:@supabase/supabase-js@2";

const CORS = {
  "Access-Control-Allow-Origin": "*", // sin cookies ni credenciales: sin la clave no se obtiene nada
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Access-Control-Allow-Headers": "content-type, authorization, apikey, x-client-info",
  "Access-Control-Max-Age": "86400",
};

const ACCIONES = new Set([
  "comprobar", "comprobar_pin", "estado", "coger", "dejar", "pasar", "avisar", "avisos", "resolver_aviso",
  "fuera_servicio", "estadisticas",
  "historial", "exportar", "guardar_dispositivo", "archivar_dispositivo", "importar_dispositivos",
  "guardar_persona", "archivar_persona", "importar_personas", "cambiar_clave", "cambiar_pin",
]);

function json(cuerpo: unknown, status = 200): Response {
  return new Response(JSON.stringify(cuerpo), {
    status,
    headers: { ...CORS, "Content-Type": "application/json; charset=utf-8", "Cache-Control": "no-store" },
  });
}

Deno.serve(async (req: Request): Promise<Response> => {
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: CORS });
  if (req.method !== "POST") return json({ ok: false, codigo: "metodo", error: "Método no permitido." }, 405);

  const texto = await req.text();
  if (texto.length > 200_000) return json({ ok: false, codigo: "tamano", error: "Petición demasiado grande." }, 413);

  let cuerpo: { clave?: unknown; accion?: unknown; args?: unknown };
  try {
    cuerpo = JSON.parse(texto);
  } catch {
    return json({ ok: false, codigo: "formato", error: "Petición no válida." }, 400);
  }
  if (typeof cuerpo?.clave !== "string" || typeof cuerpo?.accion !== "string" || !ACCIONES.has(cuerpo.accion)) {
    return json({ ok: false, codigo: "formato", error: "Petición no válida." }, 400);
  }
  const args = cuerpo.args && typeof cuerpo.args === "object" && !Array.isArray(cuerpo.args) ? cuerpo.args : {};

  const url = Deno.env.get("SUPABASE_URL");
  const clave = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!url || !clave) return json({ ok: false, codigo: "servidor", error: "Servidor mal configurado." }, 500);

  const sb = createClient(url, clave, { auth: { persistSession: false, autoRefreshToken: false } });
  const { data, error } = await sb.rpc("rd_accion", { p_clave: cuerpo.clave, p_accion: cuerpo.accion, p_args: args });
  if (error) {
    console.error("rd_accion", error.code, error.message);
    return json({ ok: false, codigo: "servidor", error: "Error del servidor." }, 500);
  }
  const rechazo = data && data.ok === false ? data.codigo : null;
  const status = rechazo === "clave" || rechazo === "sin_clave" ? 401 : rechazo === "bloqueado" ? 429 : 200;   // «pin» va con 200: el PIN no es la clave de acceso
  return json(data, status);
});
