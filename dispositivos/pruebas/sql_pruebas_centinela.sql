-- Pruebas de 008_sincronizacion_centinela.sql sobre una base vacía (nombres genéricos, sin datos reales).
-- Uso: createdb prueba && psql -d prueba -v ON_ERROR_STOP=1 -f dispositivos/pruebas/sql_pruebas_centinela.sql
\set ON_ERROR_STOP on
do $$ begin
  if not exists (select 1 from pg_roles where rolname = 'anon') then create role anon nologin; end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then create role authenticated nologin; end if;
  if not exists (select 1 from pg_roles where rolname = 'service_role') then create role service_role nologin bypassrls; end if;
end $$;
create schema if not exists extensions;
\i dispositivos/sql/001_registro_dispositivos.sql
\i dispositivos/sql/003_pin_y_avisos.sql
\i dispositivos/sql/007_mejoras.sql
-- «fuera de servicio» de antes de 008: debe pasar a averiado al aplicar la migración
update registro.config set clave_hash = extensions.crypt('clave-de-prueba-123', extensions.gen_salt('bf', 10)) where id = 1;
do $$ begin
  perform public.rd_accion('clave-de-prueba-123', 'importar_personas', '{"lineas":[{"nombre":"Ana","grupo":"jefe"},{"nombre":"Beto","grupo":"operario"}]}');
  perform public.rd_accion('clave-de-prueba-123', 'importar_dispositivos',
    '{"lineas":[{"nombre":"#1 Carretilla","grupo":"Máquina","serie":"R14 / AAA111"},{"nombre":"#2 Apilador","grupo":"Máquina","serie":"BBB222"},{"nombre":"Móvil 3","grupo":"móvil","serie":"ZY32M0001"},{"nombre":"Móvil 4","grupo":"móvil","serie":"ZY32M0002"},{"nombre":"Móvil 5","grupo":"móvil"}]}');
  perform public.rd_accion('clave-de-prueba-123', 'fuera_servicio',
    jsonb_build_object('dispositivo_id', (select id from registro.dispositivos where nombre = 'Móvil 5'), 'persona', 'Ana', 'fuera', true, 'motivo', 'antes de 008'));
end $$;
\i dispositivos/sql/008_sincronizacion_centinela.sql
\i dispositivos/sql/008_sincronizacion_centinela.sql
-- 009: sin PIN para cambiar el estado, razón siempre guardada, cambios de estado en el historial (aquí se prueba el conjunto 008 + 009)
\i dispositivos/sql/009_estado_sin_pin_con_razon.sql
\i dispositivos/sql/009_estado_sin_pin_con_razon.sql

do $t$
declare r jsonb; c text := 'clave-de-prueba-123'; d1 uuid; d2 uuid; d3 uuid; d4 uuid; d5 uuid; n int; x registro.dispositivos%rowtype;
        pend jsonb; id1 bigint; id2 bigint; dx uuid;
begin
  select id into d1 from registro.dispositivos where nombre = '#1 Carretilla';
  select id into d2 from registro.dispositivos where nombre = '#2 Apilador';
  select id into d3 from registro.dispositivos where nombre = 'Móvil 3';
  select id into d4 from registro.dispositivos where nombre = 'Móvil 4';
  select id into d5 from registro.dispositivos where nombre = 'Móvil 5';

  -- migración: lo que estaba fuera de servicio pasa a averiado con su motivo; el resto, operativo
  select * into x from registro.dispositivos where id = d5;
  assert x.estado = 'averiado' and x.estado_nota = 'antes de 008' and x.fuera, 'fuera de servicio pasa a averiado';
  assert (select count(*) from registro.dispositivos where estado = 'operativo') = 4, 'el resto operativo';

  -- estado: trae estado, nota, enlazado y pendiente_cs; el contrato anterior sigue
  r := public.rd_accion(c, 'estado');
  assert (r->'dispositivos'->0) ?& array['estado', 'estado_nota', 'estado_desde', 'enlazado', 'pendiente_cs', 'fuera', 'fuera_motivo', 'tiene'], 'estado trae los campos nuevos';
  assert r ? 'avisos' and r ? 'con_pin' and r ? 'personas', 'el contrato de estado sigue';

  -- ── cambiar_estado: validaciones ──
  r := public.rd_accion(c, 'cambiar_estado', jsonb_build_object('dispositivo_id', d1, 'persona', 'Nadie', 'estado', 'averiado', 'nota', 'frena mal'));
  assert (r->>'ok')::boolean is false and r->>'error' like 'Elige quién eres%', 'persona de la lista';
  r := public.rd_accion(c, 'cambiar_estado', jsonb_build_object('dispositivo_id', d1, 'persona', 'Ana', 'estado', 'averiado', 'nota', 'ya'));
  assert (r->>'ok')::boolean is false and r->>'error' like 'Escribe la razón%', 'razón obligatoria (5)';
  r := public.rd_accion(c, 'cambiar_estado', jsonb_build_object('dispositivo_id', d1, 'persona', 'Ana', 'estado', 'baja', 'nota', 'obsoleta'));
  assert (r->>'ok')::boolean is false and r->>'error' like 'Ese estado no vale%', 'una máquina no se da de baja';
  r := public.rd_accion(c, 'cambiar_estado', jsonb_build_object('dispositivo_id', d3, 'persona', 'Ana', 'estado', 'fallo', 'nota', 'pantalla rayada'));
  assert (r->>'ok')::boolean is false and r->>'error' like 'Ese estado no vale%', 'un móvil no tiene «con fallo»';
  r := public.rd_accion(c, 'cambiar_estado', jsonb_build_object('dispositivo_id', d1, 'persona', 'Ana', 'estado', 'roto', 'nota', 'frena mal'));
  assert (r->>'ok')::boolean is false, 'estado desconocido';

  -- ── con fallo: se puede coger; averiado: no ──
  r := public.rd_accion(c, 'cambiar_estado', jsonb_build_object('dispositivo_id', d1, 'persona', 'Ana', 'estado', 'fallo', 'nota', 'frena un poco'));
  assert (r->>'ok')::boolean, 'con fallo';
  select * into x from registro.dispositivos where id = d1;
  assert x.estado = 'fallo' and x.estado_nota = 'frena un poco' and not x.fuera and x.activo, 'con fallo no bloquea';
  r := public.rd_accion(c, 'coger', jsonb_build_object('dispositivo_id', d1, 'persona', 'Beto'));
  assert (r->>'ok')::boolean and (select tiene from registro.dispositivos where id = d1) = 'Beto', 'con fallo se puede coger';
  r := public.rd_accion(c, 'cambiar_estado', jsonb_build_object('dispositivo_id', d1, 'persona', 'Ana', 'estado', 'fallo', 'nota', 'frena un poco'));
  assert (r->>'ya')::boolean, 'mismo estado y nota = ya';

  r := public.rd_accion(c, 'cambiar_estado', jsonb_build_object('dispositivo_id', d1, 'persona', 'Ana', 'estado', 'averiado', 'nota', 'no frena'));
  select * into x from registro.dispositivos where id = d1;
  assert x.estado = 'averiado' and x.fuera and x.fuera_motivo = 'no frena' and x.tiene = 'Beto', 'averiado bloquea (y sigue en manos de quien lo tenía)';
  assert (select count(*) from registro.fuera_log where dispositivo_id = d1 and accion = 'fuera') = 1, 'cuenta como parada';
  r := public.rd_accion(c, 'dejar', jsonb_build_object('dispositivo_id', d1, 'persona', 'Beto'));
  r := public.rd_accion(c, 'coger', jsonb_build_object('dispositivo_id', d1, 'persona', 'Ana'));
  assert (r->>'ok')::boolean is false and r->>'codigo' = 'fuera', 'una averiada no se puede coger';
  r := public.rd_accion(c, 'cambiar_estado', jsonb_build_object('dispositivo_id', d1, 'persona', 'Ana', 'estado', 'reparacion', 'nota', 'lo ve el SAT'));
  assert (select fuera from registro.dispositivos where id = d1), 'en reparación sigue bloqueada';
  assert (select count(*) from registro.fuera_log where dispositivo_id = d1) = 1, 'averiado → reparación no es otra parada';
  r := public.rd_accion(c, 'cambiar_estado', jsonb_build_object('dispositivo_id', d1, 'persona', 'Ana', 'estado', 'operativo', 'nota', 'ignorada'));
  select * into x from registro.dispositivos where id = d1;
  assert x.estado = 'operativo' and not x.fuera and x.estado_nota is null and x.fuera_motivo is null, 'vuelve a operativo';
  assert (select count(*) from registro.fuera_log where dispositivo_id = d1 and accion = 'servicio') = 1, 'cuenta la vuelta al servicio';

  -- baja: un móvil en uso se suelta solo, desaparece (activo=false) y reaparece al volver
  perform public.rd_accion(c, 'coger', jsonb_build_object('dispositivo_id', d3, 'persona', 'Beto'));
  r := public.rd_accion(c, 'cambiar_estado', jsonb_build_object('dispositivo_id', d3, 'persona', 'Ana', 'estado', 'baja'));
  assert (r->>'ok')::boolean, 'baja sin nota';
  select * into x from registro.dispositivos where id = d3;
  assert not x.activo and x.estado = 'baja' and x.tiene is null and x.desde is null, 'baja: archivado y libre';
  assert exists (select 1 from registro.movimientos where dispositivo_id = d3 and accion = 'dejar' and automatico and nota = 'Dado de baja' and persona = 'Beto'), 'baja deja el «dejar» automático';

  -- ── la «fuera de servicio» de siempre sigue funcionando y se refleja en el estado ──
  r := public.rd_accion(c, 'fuera_servicio', jsonb_build_object('dispositivo_id', d2, 'persona', 'Ana', 'fuera', true, 'motivo', 'sin batería'));
  select * into x from registro.dispositivos where id = d2;
  assert x.fuera and x.estado = 'averiado' and x.estado_nota = 'sin batería', 'fuera_servicio = averiado';
  r := public.rd_accion(c, 'fuera_servicio', jsonb_build_object('dispositivo_id', d2, 'persona', 'Ana', 'fuera', true, 'motivo', 'otra vez'));
  assert (r->>'ya')::boolean, 'fuera_servicio repetido = ya';
  r := public.rd_accion(c, 'fuera_servicio', jsonb_build_object('dispositivo_id', d2, 'persona', 'Ana', 'fuera', false));
  assert not (select fuera from registro.dispositivos where id = d2) and (select estado from registro.dispositivos where id = d2) = 'operativo', 'en servicio';

  -- ── cola para Centinela: lo hecho en Anubis sobre algo NO vinculado no espera nada ──
  assert not exists (select 1 from registro.cambios_estado where fuente = 'anubis' and not aplicado), 'sin vínculo no hay cola';

  -- ── sync_centinela: vincular por serie, crear altas, estados ──
  r := public.rd_accion(c, 'sync_centinela', jsonb_build_object('simular', true, 'items', jsonb_build_array(
        jsonb_build_object('origen', 'maquinaria', 'origen_id', '1', 'nombre', '#1 Carretilla', 'serie', 'r14 / aaa111', 'estado', 'fallo', 'nota', 'ruido raro'),
        jsonb_build_object('origen', 'maquinaria', 'origen_id', '3', 'nombre', '#3 Nueva', 'serie', 'CCC333', 'estado', 'operativo'),
        jsonb_build_object('origen', 'dispositivos', 'origen_id', '7', 'nombre', '#7 Zebra Recepción', 'grupo', 'Móvil / lector', 'serie', 'ZY32M0002', 'estado', 'averiado', 'nota', 'no carga'))));
  assert (r->>'ok')::boolean and (r->>'simulado')::boolean, 'simulación';
  assert (r->'resumen'->>'vinculados')::int = 2 and (r->'resumen'->>'creados')::int = 1 and (r->'resumen'->>'estados')::int = 2, 'la simulación cuenta lo que haría: ' || (r->'resumen')::text;
  assert (select count(*) from registro.dispositivos where origen is not null) = 0 and (select count(*) from registro.dispositivos) = 5, 'la simulación no escribe nada';

  r := public.rd_accion(c, 'sync_centinela', jsonb_build_object('items', jsonb_build_array(
        jsonb_build_object('origen', 'maquinaria', 'origen_id', '1', 'nombre', '#1 Carretilla', 'serie', 'r14 / aaa111', 'estado', 'fallo', 'nota', 'ruido raro'),
        jsonb_build_object('origen', 'maquinaria', 'origen_id', '3', 'nombre', '#3 Nueva', 'serie', 'CCC333', 'estado', 'operativo'),
        jsonb_build_object('origen', 'dispositivos', 'origen_id', '7', 'nombre', '#7 Zebra Recepción', 'grupo', 'Móvil / lector', 'serie', 'ZY32M0002', 'estado', 'averiado', 'nota', 'no carga'),
        jsonb_build_object('origen', 'dispositivos', 'origen_id', '8', 'nombre', 'Vieja', 'serie', 'ZZZ', 'estado', 'baja'),
        jsonb_build_object('origen', 'maquinaria', 'origen_id', '9', 'estado', 'baja'),
        jsonb_build_object('origen', 'otra', 'origen_id', '1', 'estado', 'operativo'))));
  assert (r->>'ok')::boolean, 'sync';
  assert (r->'resumen'->>'vinculados')::int = 2 and (r->'resumen'->>'creados')::int = 1 and (r->'resumen'->>'ignorados')::int = 3, 'resumen: ' || (r->'resumen')::text;
  select * into x from registro.dispositivos where id = d1;
  assert x.origen = 'maquinaria' and x.origen_id = '1' and x.estado = 'fallo' and x.estado_nota = 'ruido raro' and x.nombre = '#1 Carretilla', 'vinculada por serie (sin distinguir mayúsculas) y con el estado de Centinela';
  select * into x from registro.dispositivos where id = d4;
  assert x.origen = 'dispositivos' and x.origen_id = '7' and x.estado = 'averiado' and x.fuera and x.fuera_motivo = 'no carga', 'móvil vinculado y averiado';
  assert (select count(*) from registro.dispositivos where nombre = '#3 Nueva' and origen = 'maquinaria' and grupo = 'Máquina' and estado = 'operativo') = 1, 'alta nueva';
  assert not exists (select 1 from registro.dispositivos where nombre = 'Vieja'), 'una baja no se da de alta';
  assert not exists (select 1 from registro.cambios_estado where fuente = 'anubis' and not aplicado), 'lo de Centinela no entra en la cola';

  -- el estado «averiado» de Centinela bloquea y el estado vuelve a operativo cuando Centinela lo dice
  r := public.rd_accion(c, 'coger', jsonb_build_object('dispositivo_id', d4, 'persona', 'Ana'));
  assert r->>'codigo' = 'fuera', 'averiado desde Centinela no se puede coger';

  -- repetir la sincronización no cambia nada
  r := public.rd_accion(c, 'sync_centinela', jsonb_build_object('items', jsonb_build_array(
        jsonb_build_object('origen', 'maquinaria', 'origen_id', '1', 'serie', 'R14 / AAA111', 'estado', 'fallo', 'nota', 'ruido raro'),
        jsonb_build_object('origen', 'maquinaria', 'origen_id', '3', 'serie', 'CCC333', 'estado', 'operativo'))));
  assert (r->'resumen'->>'sin_cambio')::int = 2 and (r->'resumen'->>'estados')::int = 0 and (r->'resumen'->>'creados')::int = 0, 'idempotente: ' || (r->'resumen')::text;

  -- ── cambio hecho en Anubis sobre algo vinculado → cola ──
  r := public.rd_accion(c, 'cambiar_estado', jsonb_build_object('dispositivo_id', d1, 'persona', 'Ana', 'estado', 'averiado', 'nota', 'ya no frena'));
  assert (select pendiente_cs from jsonb_to_recordset(r->'dispositivos') as t(id uuid, pendiente_cs boolean) where id = d1), 'estado marca el cambio como pendiente de Centinela';
  r := public.rd_accion(c, 'cambiar_estado', jsonb_build_object('dispositivo_id', d4, 'persona', 'Beto', 'estado', 'operativo'));

  -- Centinela manda lo suyo (todavía ve el estado viejo): NO pisa lo pendiente, y recibe la cola
  r := public.rd_accion(c, 'sync_centinela', jsonb_build_object('items', jsonb_build_array(
        jsonb_build_object('origen', 'maquinaria', 'origen_id', '1', 'serie', 'R14 / AAA111', 'estado', 'fallo', 'nota', 'ruido raro'),
        jsonb_build_object('origen', 'dispositivos', 'origen_id', '7', 'serie', 'ZY32M0002', 'estado', 'averiado', 'nota', 'no carga'))));
  assert (r->'resumen'->>'esperando')::int = 2 and (r->'resumen'->>'estados')::int = 0, 'lo pendiente no se pisa: ' || (r->'resumen')::text;
  assert (select estado from registro.dispositivos where id = d1) = 'averiado' and (select estado from registro.dispositivos where id = d4) = 'operativo', 'siguen los estados de Anubis';
  pend := r->'pendientes';
  assert jsonb_array_length(pend) = 2, 'dos cambios pendientes';
  assert pend->0->>'estado' = 'averiado' and pend->0->>'origen' = 'maquinaria' and pend->0->>'origen_id' = '1' and pend->0->>'nota' = 'ya no frena' and pend->0->>'por' = 'Ana', 'primer pendiente completo';
  assert pend->1->>'estado' = 'operativo' and pend->1->>'origen' = 'dispositivos' and pend->1->>'origen_id' = '7', 'segundo pendiente (en orden)';
  id1 := (pend->0->>'id')::bigint; id2 := (pend->1->>'id')::bigint;

  -- Centinela confirma el primero (bien) y el segundo (con error): la cola se vacía y manda Centinela
  r := public.rd_accion(c, 'sync_centinela', jsonb_build_object(
        'acks', jsonb_build_array(jsonb_build_object('id', id1, 'ok', true), jsonb_build_object('id', id2, 'ok', false, 'error', 'no pude')),
        'items', jsonb_build_array(
          jsonb_build_object('origen', 'maquinaria', 'origen_id', '1', 'serie', 'R14 / AAA111', 'estado', 'averiado', 'nota', 'ya no frena'),
          jsonb_build_object('origen', 'dispositivos', 'origen_id', '7', 'serie', 'ZY32M0002', 'estado', 'averiado', 'nota', 'no carga'))));
  assert jsonb_array_length(r->'pendientes') = 0, 'cola vacía';
  assert (select count(*) from registro.cambios_estado where fuente = 'anubis' and not aplicado) = 0, 'todo confirmado';
  assert (select resultado from registro.cambios_estado where id = id2) like 'ERROR: no pude%', 'se guarda el error';
  assert (select estado from registro.dispositivos where id = d4) = 'averiado', 'tras fallar Centinela, vuelve a mandar Centinela (averiado)';
  assert (select estado from registro.dispositivos where id = d1) = 'averiado', 'lo aplicado coincide';

  -- Centinela vuelve a poner operativo / reactiva una baja
  r := public.rd_accion(c, 'sync_centinela', jsonb_build_object('items', jsonb_build_array(
        jsonb_build_object('origen', 'maquinaria', 'origen_id', '1', 'serie', 'R14 / AAA111', 'estado', 'operativo'))));
  select * into x from registro.dispositivos where id = d1;
  assert x.estado = 'operativo' and not x.fuera and x.fuera_motivo is null, 'Centinela devuelve a operativo';
  perform public.rd_accion(c, 'cambiar_estado', jsonb_build_object('dispositivo_id', d4, 'persona', 'Ana', 'estado', 'operativo'));
  update registro.cambios_estado set aplicado = true where not aplicado;
  r := public.rd_accion(c, 'sync_centinela', jsonb_build_object('items', jsonb_build_array(
        jsonb_build_object('origen', 'dispositivos', 'origen_id', '7', 'serie', 'ZY32M0002', 'estado', 'baja'))));
  assert not (select activo from registro.dispositivos where id = d4), 'baja desde Centinela: archivado';
  r := public.rd_accion(c, 'sync_centinela', jsonb_build_object('items', jsonb_build_array(
        jsonb_build_object('origen', 'dispositivos', 'origen_id', '7', 'serie', 'ZY32M0002', 'estado', 'operativo'))));
  assert (select activo from registro.dispositivos where id = d4) and (select estado from registro.dispositivos where id = d4) = 'operativo', 'reactivado al salir de baja';

  -- un dispositivo archivado A MANO en Anubis (no es baja) no se reactiva solo
  update registro.dispositivos set activo = false where id = d2;
  select count(*) into n from registro.dispositivos;
  r := public.rd_accion(c, 'sync_centinela', jsonb_build_object('items', jsonb_build_array(
        jsonb_build_object('origen', 'maquinaria', 'origen_id', '2', 'serie', 'BBB222', 'estado', 'operativo'))));
  assert not (select activo from registro.dispositivos where id = d2) and (select origen_id from registro.dispositivos where id = d2) = '2', 'archivado a mano sigue archivado';
  assert (select count(*) from registro.dispositivos) = n, 'no se duplica';

  -- altas de dispositivos: por defecto NO se crean (se informan como «sin vincular»); con crear.dispositivos sí
  r := public.rd_accion(c, 'sync_centinela', jsonb_build_object('items', jsonb_build_array(
        jsonb_build_object('origen', 'dispositivos', 'origen_id', '30', 'nombre', '#30 Zebra Muelle', 'grupo', 'Móvil / lector', 'serie', '356938035643809', 'estado', 'operativo'))));
  assert (r->'resumen'->>'creados')::int = 0 and (r->'resumen'->>'sin_vincular')::int = 1 and r->'sin_vincular'->0->>'nombre' = '#30 Zebra Muelle', 'sin crear.dispositivos no se da de alta';
  assert not exists (select 1 from registro.dispositivos where origen_id = '30'), 'no se creó';
  r := public.rd_accion(c, 'sync_centinela', jsonb_build_object('crear', jsonb_build_object('dispositivos', true), 'items', jsonb_build_array(
        jsonb_build_object('origen', 'dispositivos', 'origen_id', '30', 'nombre', '#30 Zebra Muelle', 'grupo', 'Móvil / lector', 'serie', '356938035643809', 'estado', 'operativo'))));
  assert (r->'resumen'->>'creados')::int = 1 and exists (select 1 from registro.dispositivos where origen = 'dispositivos' and origen_id = '30' and grupo = 'Móvil / lector'), 'con crear.dispositivos se da de alta';
  r := public.rd_accion(c, 'sync_centinela', jsonb_build_object('crear', jsonb_build_object('maquinaria', false), 'items', jsonb_build_array(
        jsonb_build_object('origen', 'maquinaria', 'origen_id', '31', 'nombre', '#31 Otra', 'serie', 'EEE555', 'estado', 'operativo'))));
  assert (r->'resumen'->>'creados')::int = 0 and (r->'resumen'->>'sin_vincular')::int = 1, 'crear.maquinaria=false no da de alta';

  -- máquinas: si la serie no coincide, se vincula por el número del nombre («#N …»), sin duplicar
  insert into registro.dispositivos (nombre, grupo, serie) values ('#40 Elevadora Still', 'Máquina', 'serie con formato distinto');
  select count(*) into n from registro.dispositivos;
  r := public.rd_accion(c, 'sync_centinela', jsonb_build_object('items', jsonb_build_array(
        jsonb_build_object('origen', 'maquinaria', 'origen_id', '40', 'nombre', '#40 Elevadora Still', 'serie', 'otra serie', 'estado', 'fallo', 'nota', 'ruido extraño'))));
  assert (r->'resumen'->>'vinculados')::int = 1 and (r->'resumen'->>'creados')::int = 0 and (select count(*) from registro.dispositivos) = n, 'vinculada por número, sin duplicar';
  assert (select estado || '|' || serie from registro.dispositivos where origen = 'maquinaria' and origen_id = '40') = 'fallo|otra serie', 'estado y serie de Centinela';
  insert into registro.dispositivos (nombre, grupo, serie) values ('#400 Otra', 'Máquina', null);
  r := public.rd_accion(c, 'sync_centinela', jsonb_build_object('items', jsonb_build_array(
        jsonb_build_object('origen', 'maquinaria', 'origen_id', '4', 'nombre', '#4 Nueva', 'serie', 'FFF666', 'estado', 'operativo'))));
  assert (r->'resumen'->>'creados')::int = 1, 'el número 4 no se confunde con #400';

  -- nombres repetidos: el alta se renombra con (2)
  r := public.rd_accion(c, 'sync_centinela', jsonb_build_object('items', jsonb_build_array(
        jsonb_build_object('origen', 'maquinaria', 'origen_id', '20', 'nombre', '#3 Nueva', 'serie', 'DDD444', 'estado', 'operativo'))));
  assert exists (select 1 from registro.dispositivos where nombre = '#3 Nueva (2)'), 'nombre repetido';

  -- ── PIN (009): cambiar_estado y fuera_servicio ya NO lo piden; sync_centinela y la zona de jefes SÍ ──
  update registro.config set pin_hash = extensions.crypt('1234', extensions.gen_salt('bf', 10)) where id = 1;
  r := public.rd_accion(c, 'cambiar_estado', jsonb_build_object('dispositivo_id', d1, 'persona', 'Beto', 'estado', 'averiado', 'nota', 'sin pin y operario'));
  assert (r->>'ok')::boolean, 'cambiar_estado NO pide PIN y lo puede hacer un operario: ' || r::text;
  assert (select estado || '|' || estado_nota || '|' || estado_por from registro.dispositivos where id = d1) = 'averiado|sin pin y operario|Beto', 'razón y autor guardados';
  assert (select (e->>'estado_por') from jsonb_array_elements(r->'dispositivos') e where (e->>'id')::uuid = d1) = 'Beto', 'estado trae estado_por';
  r := public.rd_accion(c, 'fuera_servicio', jsonb_build_object('dispositivo_id', d1, 'persona', 'Beto', 'fuera', false, 'motivo', 'cambiadas las pastillas'));
  assert (r->>'ok')::boolean, 'fuera_servicio NO pide PIN: ' || r::text;
  r := public.rd_accion(c, 'sync_centinela', jsonb_build_object('items', '[]'::jsonb));
  assert r->>'codigo' = 'pin', 'sync_centinela pide PIN';
  r := public.rd_accion(c, 'sync_centinela', jsonb_build_object('pin', '1234', 'items', '[]'::jsonb));
  assert (r->>'ok')::boolean, 'con PIN pasa';
  r := public.rd_accion(c, 'historial', '{}'::jsonb);
  assert r->>'codigo' = 'pin', 'el historial sigue pidiendo PIN';
  r := public.rd_accion(c, 'estadisticas', '{}'::jsonb);
  assert r->>'codigo' = 'pin', 'las estadísticas siguen pidiendo PIN';
  r := public.rd_accion(c, 'avisos', '{}'::jsonb);
  assert r->>'codigo' = 'pin', 'los avisos de jefes siguen pidiendo PIN';

  select id into dx from registro.dispositivos where origen = 'maquinaria' and origen_id = '3';
  -- ── razón siempre guardada (009) ──
  select count(*) into n from registro.cambios_estado where dispositivo_id = dx;
  r := public.rd_accion(c, 'cambiar_estado', jsonb_build_object('dispositivo_id', dx, 'persona', 'Ana', 'estado', 'reparacion', 'nota', 'lo mira el SAT'));
  r := public.rd_accion(c, 'cambiar_estado', jsonb_build_object('dispositivo_id', dx, 'persona', 'Beto', 'estado', 'operativo', 'nota', 'cambiado el cargador'));
  select * into x from registro.dispositivos where id = dx;
  assert x.estado = 'operativo' and x.estado_nota is null and x.estado_por = 'Beto', 'vuelve a operativo sin razón vigente';
  assert (select nota from registro.cambios_estado where dispositivo_id = dx order by id desc limit 1) = 'cambiado el cargador', 'la razón de volver a operativo queda en el registro de cambios';
  r := public.rd_accion(c, 'cambiar_estado', jsonb_build_object('dispositivo_id', dx, 'persona', 'Ana', 'estado', 'operativo', 'nota', 'otra vez'));
  assert (r->>'ya')::boolean, 'operativo sobre operativo = ya (aunque lleve razón)';
  assert (select count(*) from registro.cambios_estado where dispositivo_id = dx) = n + 2, 'y no añade fila';
  r := public.rd_accion(c, 'cambiar_estado', jsonb_build_object('dispositivo_id', dx, 'persona', 'Ana', 'estado', 'fallo', 'nota', 'se oye un ruido'));
  r := public.rd_accion(c, 'cambiar_estado', jsonb_build_object('dispositivo_id', dx, 'persona', 'Ana', 'estado', 'fallo', 'nota', 'ahora además vibra'));
  assert not coalesce((r->>'ya')::boolean, false) and (select estado_nota from registro.dispositivos where id = dx) = 'ahora además vibra', 'misma situación con otra razón = cambio de razón';
  r := public.rd_accion(c, 'cambiar_estado', jsonb_build_object('dispositivo_id', dx, 'persona', 'Ana', 'estado', 'operativo'));

  -- a Centinela solo le llega la razón si el estado NO es operativo (como hasta ahora)
  update registro.cambios_estado set aplicado = true where not aplicado;
  r := public.rd_accion(c, 'sync_centinela', jsonb_build_object('pin', '1234', 'items', jsonb_build_array(
        jsonb_build_object('origen', 'maquinaria', 'origen_id', '3', 'serie', 'CCC333', 'estado', 'operativo'))));
  perform public.rd_accion(c, 'cambiar_estado', jsonb_build_object('dispositivo_id', dx, 'persona', 'Ana', 'estado', 'averiado', 'nota', 'sin frenos del todo'));
  perform public.rd_accion(c, 'cambiar_estado', jsonb_build_object('dispositivo_id', dx, 'persona', 'Ana', 'estado', 'operativo', 'nota', 'frenos nuevos'));
  r := public.rd_accion(c, 'sync_centinela', jsonb_build_object('pin', '1234', 'items', '[]'::jsonb));
  assert jsonb_array_length(r->'pendientes') = 2, 'dos pendientes para Centinela: ' || (r->'pendientes')::text;
  assert r->'pendientes'->0->>'estado' = 'averiado' and r->'pendientes'->0->>'nota' = 'sin frenos del todo', 'averiado lleva la razón';
  assert r->'pendientes'->1->>'estado' = 'operativo' and (r->'pendientes'->1->'nota') = 'null'::jsonb, 'operativo no manda razón a Centinela';
  update registro.cambios_estado set aplicado = true where not aplicado;

  -- ── historial con los cambios de estado (009) ──
  r := public.rd_accion(c, 'historial', jsonb_build_object('pin', '1234', 'accion', 'estado', 'dispositivo_id', dx));
  assert (r->>'ok')::boolean and jsonb_array_length(r->'filas') >= 4, 'historial de estados: ' || r::text;
  assert r->'filas'->0->>'accion' = 'estado' and r->'filas'->0->>'estado' = 'operativo' and r->'filas'->0->>'estado_anterior' = 'averiado'
         and r->'filas'->0->>'nota' = 'frenos nuevos' and r->'filas'->0->>'persona' = 'Ana' and r->'filas'->0->>'dispositivo' = '#3 Nueva', 'la fila trae estado, anterior, razón y quién: ' || (r->'filas'->0)::text;
  assert not exists (select 1 from jsonb_array_elements(r->'filas') f where f->>'accion' <> 'estado'), 'con el filtro «estado» solo salen cambios de estado';
  r := public.rd_accion(c, 'historial', jsonb_build_object('pin', '1234', 'accion', 'coger'));
  assert not exists (select 1 from jsonb_array_elements(r->'filas') f where f->>'accion' <> 'coger'), 'con «coger» no salen estados';
  r := public.rd_accion(c, 'historial', jsonb_build_object('pin', '1234', 'limite', 500));
  assert exists (select 1 from jsonb_array_elements(r->'filas') f where f->>'accion' = 'estado' and f->>'persona' = 'Centinela')
     and exists (select 1 from jsonb_array_elements(r->'filas') f where f->>'accion' = 'coger'), 'sin filtro: mezcla movimientos y estados (los de Centinela salen como Centinela)';
  assert (select count(*) from jsonb_array_elements(r->'filas') f where f->>'accion' = 'estado')
       = (select count(*) from registro.cambios_estado), 'todos los cambios de estado salen';
  r := public.rd_accion(c, 'historial', jsonb_build_object('pin', '1234', 'persona', 'Beto', 'accion', 'estado'));
  assert jsonb_array_length(r->'filas') >= 2 and not exists (select 1 from jsonb_array_elements(r->'filas') f where f->>'persona' <> 'Beto'), 'filtro por persona vale también para estados';
  r := public.rd_accion(c, 'historial', jsonb_build_object('pin', '1234', 'accion', 'nada'));
  assert (r->>'ok')::boolean is false, 'filtro de acción desconocido';
  r := public.rd_accion(c, 'historial', jsonb_build_object('pin', '1234', 'limite', 3, 'desplazamiento', 0));
  assert jsonb_array_length(r->'filas') = 3 and (r->>'mas')::boolean, 'paginación: hay más';

  -- ── permisos: nada público ──
  assert not has_function_privilege('anon', 'public.rd_accion(text,text,jsonb)', 'execute'), 'anon no ejecuta rd_accion';
  assert not has_table_privilege('anon', 'registro.cambios_estado', 'select'), 'anon no lee la cola';
  assert has_function_privilege('service_role', 'public.rd_accion(text,text,jsonb)', 'execute'), 'service_role sí';

  raise notice 'TODO OK (008 + 009)';
end $t$;
