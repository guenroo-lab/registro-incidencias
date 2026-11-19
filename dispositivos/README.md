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
- `sql/003_pin_y_avisos.sql`: PIN de 4 dígitos (hash bcrypt, 10 fallos en 10 minutos bloquean 10 minutos) y avisos de avería.
  Con PIN puesto, el **servidor** lo exige para historial, exportar, avisos de los jefes, resolver avisos, ajustes y cambio de clave
  o de PIN; coger, dejar, avisar y ver el estado no lo piden. Sin PIN puesto no se exige. La migración no lleva ningún PIN.
- `sql/007_mejoras.sql` (requiere 001 y 003; re-ejecutable): fuera de servicio, traspaso directo («pasar»), estadísticas y hora real de los
  apuntes hechos sin conexión (`cuando`: hasta 2 días antes, nunca en el futuro ni antes del último movimiento; los reenvíos no
  duplican nada). `sql/007_deshacer.sql` la quita (vuelve a 001 + 003 y borra el registro de paradas).
- `sql/002_deshacer.sql`: lo quita todo (**borra** también el historial).
- `pruebas/sql_pruebas.sql`, `pruebas/sql_pruebas_pin_avisos.sql` y `pruebas/sql_pruebas_mejoras.sql`: pruebas de la base de datos para un
  Postgres local vacío (ver la cabecera de cada archivo).
- `manifest.webmanifest`, `sw.js` e `icono-*.png`: la web se puede instalar en el móvil y abre sin cobertura (el service worker guarda
  solo la propia web y las tipografías; las llamadas al servidor nunca pasan por él). Para obligar a recargar a todos, cambiar `VERSION` en `sw.js`.

Los datos iniciales (personas y dispositivos) y la clave **no están en este repositorio** (es público): se cargan aparte.

## Poner en marcha / mover a otro proyecto de Supabase

1. Ejecutar `sql/001_registro_dispositivos.sql`, `sql/003_pin_y_avisos.sql` y `sql/007_mejoras.sql` en el editor SQL del proyecto (si el editor
   corta textos largos, partirlos por funciones en trozos de unos 8.000 caracteres).
2. Cargar las personas y los dispositivos iniciales (o dejarlas vacías y usar Ajustes → Importar lista).
3. Fijar la clave inicial (guardada con hash):
   `update registro.config set clave_hash = extensions.crypt('LA-CLAVE', extensions.gen_salt('bf', 10)) where id = 1;`
   Y el PIN de los jefes (o ponerlo desde Ajustes → Otros → «Poner un PIN»):
   `update registro.config set pin_hash = extensions.crypt('1234', extensions.gen_salt('bf', 10)) where id = 1;`
4. Desplegar `supabase/dispositivos.ts` como función `dispositivos` sin verificación de JWT.
5. Si el proyecto es otro, cambiar la dirección de la función en `index.html` (constante `API`).

## Notas de uso

- «Cogerlo yo» sobre algo ocupado lo pasa de una persona a otra y deja constancia de que la primera lo deja.
- Dejar lo puede registrar otra persona (queda «lo registró X»).
- Archivar un dispositivo o una persona la quita de las listas pero conserva el historial. No se puede archivar algo en uso.
- Importar lista: una línea por dispositivo, `Nombre ; Tipo ; Serie` (tipo y serie opcionales), o columnas pegadas desde una hoja.
- **PIN de jefes:** las pestañas Avisos, Historial y Ajustes están escondidas detrás del candado «Jefes». Se bloquean solas tras
  10 minutos sin tocar nada y con el botón del candado. El PIN se cambia en Ajustes → Otros.
- **Avisos:** «Avisar de un problema» (en el cuadro de cualquier dispositivo) deja un aviso con quién y qué. Sale como insignia
  en el cuadro, en un banner de «Ahora» y al coger ese dispositivo. Los jefes los ven en Avisos y los marcan como resueltos.
- **Mensajes:** al coger una máquina sale «Revisa el agua y el estado antes de coger la máquina»; al dejar un móvil o lector,
  «Asegúrate de dejar bien conectado el dispositivo en carga».
- **Fuera de servicio:** un jefe (con el PIN) pone una máquina o dispositivo fuera de servicio con un motivo; nadie puede cogerlo ni
  pasarlo hasta que un jefe lo vuelva a poner en servicio. Sale rayado en los cuadros, con una tarjeta de cuenta en «Ahora».
- **Pasar a otra persona:** en un cuadro ocupado, «Pasar a otra persona» anota en un paso que quien lo tenía lo deja y que la otra
  persona lo recibe, con la misma hora.
- **Cierre de turno:** en la última media hora de cada turno (mañana 14:00, tarde 22:00) y la siguiente sale una lista de lo que
  sigue sin devolver, con «Dejar» y «Pasar» en cada fila (una vez por turno y aparato); el botón «Cierre de turno» de «Ahora» la abre
  cuando quieras. Además, Centinela manda por correo el aviso de las 8 h y la lista del cierre a los jefes (ver `AvisosRegistroDispositivos.gs`
  en el repositorio de Centinela).
- **Estadísticas (jefes):** dentro de Historial. Usos, horas, olvidos de más de 8 h, traspasos, paradas, quién y qué más se usa, lo que
  no se usa y las horas con más movimiento, a 7, 30 o 90 días.
- **Sin cobertura:** coger, dejar, pasar y avisar se guardan en el aparato y se envían solos al volver la cobertura, con la hora real.
  Lo que pide PIN no se aplaza. Si al enviarlo el servidor lo rechaza, sale un aviso con lo que no se pudo guardar.
- **Tema:** por defecto claro con el rojo Taisa; quien ya eligió otro tema lo conserva.
