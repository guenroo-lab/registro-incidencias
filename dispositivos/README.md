# Registro de dispositivos

Web simple (móvil y ordenador) para apuntar **quién coge cada dispositivo o máquina y cuándo lo deja**.
Pantalla de **cuadros** (verde = libre, color de acento = ocupado, ámbar = lleva cogido desde un día anterior),
botones **Coger / Dejar**, **historial** con filtros (dispositivo, persona, movimiento, fechas) y descarga en CSV,
y **Ajustes** para editar las listas de dispositivos y personas. Mismo estilo que RYU y Kairos.

Está **fuera del entorno de Leroy Merlin**: web estática en GitHub Pages + una base de datos propia en Supabase.
No hay conexión en vivo con ningún sistema de la empresa: las listas se copiaron una vez y se editan en Ajustes.

## Cómo se entra

Con un enlace que lleva la clave: `https://guenroo-lab.github.io/registro-incidencias/dispositivos/?k=<clave>`.
La web guarda la clave en ese aparato y la quita de la barra de direcciones. Sin clave solo se ve la pantalla de acceso.
La clave se cambia en **Ajustes → Otros → Cambiar la clave** (hay que pasar el enlace nuevo a los demás).

## Cómo está montado

```
navegador ──POST {clave, accion, args}──▶ función de borde «dispositivos» ──▶ public.rd_accion() ──▶ esquema «registro»
```

- `index.html`: toda la web (sin dependencias salvo la tipografía de Google Fonts). No lleva ningún secreto: solo la dirección de la función.
- `supabase/dispositivos.ts`: función de borde (sin verificación de JWT). Valida la forma de la petición y llama a `rd_accion` con la
  clave de servicio, que vive solo en el entorno de la función.
- `sql/001_registro_dispositivos.sql`: esquema `registro` (tablas con RLS y **sin permisos** para `anon`/`authenticated`) y la única
  puerta, `public.rd_accion(clave, accion, args)`, `security definer`, ejecutable solo por `service_role`. La clave se guarda con
  bcrypt; 50 intentos fallidos en 10 minutos bloquean los intentos 10 minutos. Re-ejecutable.
- `sql/002_deshacer.sql`: lo quita todo (**borra** también el historial).
- `pruebas/sql_pruebas.sql`: pruebas de la base de datos para un Postgres local vacío (ver cabecera del archivo).

Los datos iniciales (personas y dispositivos) y la clave **no están en este repositorio** (es público): se cargan aparte.

## Poner en marcha / mover a otro proyecto de Supabase

1. Ejecutar `sql/001_registro_dispositivos.sql` en el editor SQL del proyecto.
2. Cargar las personas y los dispositivos iniciales (o dejarlas vacías y usar Ajustes → Importar lista).
3. Fijar la clave inicial (guardada con hash):
   `update registro.config set clave_hash = extensions.crypt('LA-CLAVE', extensions.gen_salt('bf', 10)) where id = 1;`
4. Desplegar `supabase/dispositivos.ts` como función `dispositivos` sin verificación de JWT.
5. Si el proyecto es otro, cambiar la dirección de la función en `index.html` (constante `API`).

## Notas de uso

- «Cogerlo yo» sobre algo ocupado lo pasa de una persona a otra y deja constancia de que la primera lo deja.
- Dejar lo puede registrar otra persona (queda «lo registró X»).
- Archivar un dispositivo o una persona la quita de las listas pero conserva el historial. No se puede archivar algo en uso.
- Importar lista: una línea por dispositivo, `Nombre ; Tipo ; Serie` (tipo y serie opcionales), o columnas pegadas desde una hoja.
