\set ON_ERROR_STOP on
do $r$ begin
  begin create role anon nologin; exception when duplicate_object then null; end;
  begin create role authenticated nologin; exception when duplicate_object then null; end;
  begin create role service_role nologin bypassrls; exception when duplicate_object then null; end;
end $r$;
create schema if not exists extensions;
-- Pruebas de la base de datos: ejecutar en un Postgres LOCAL vacío (nunca en producción):
--   psql -h <socket> -U postgres -d <base_vacia> -v ON_ERROR_STOP=1 -f sql_pruebas.sql   (desde esta carpeta)
-- Crea los roles anon/authenticated/service_role y el esquema extensions como en Supabase, aplica la migración
-- dos veces (debe ser re-ejecutable) y comprueba cada acción, la clave, el bloqueo y que anon/authenticated no pueden nada.
\i ../sql/001_registro_dispositivos.sql
\i ../sql/001_registro_dispositivos.sql

-- clave inicial
update registro.config set clave_hash = extensions.crypt('clave-de-prueba-123', extensions.gen_salt('bf', 10)) where id = 1;

do $t$
declare r jsonb; d1 uuid; d2 uuid; p1 text := 'Persona A'; n int;
begin
  -- clave
  r := public.rd_accion('mala', 'estado'); assert r->>'codigo' = 'clave', 'clave mala: ' || r;
  r := public.rd_accion(null, 'estado');   assert r->>'codigo' = 'clave', 'clave nula';
  r := public.rd_accion('clave-de-prueba-123', 'comprobar'); assert (r->>'ok')::boolean, 'comprobar ok';
  r := public.rd_accion('clave-de-prueba-123', 'nada'); assert r->>'codigo' = 'accion', 'accion desconocida';

  -- importar personas y dispositivos
  r := public.rd_accion('clave-de-prueba-123', 'importar_personas', '{"lineas":[{"nombre":"Persona A","grupo":"Operario"},{"nombre":"Persona B","grupo":"jefe"},{"nombre":"persona a"},{"nombre":""}]}');
  assert (r->>'nuevos')::int = 2 and (r->>'existentes')::int = 1, 'importar personas: ' || r;
  r := public.rd_accion('clave-de-prueba-123', 'importar_dispositivos', '{"lineas":[{"nombre":"#1 Transpaleta Linde","grupo":"Máquina","serie":"W41156P05118"},{"nombre":"Wyse 3040 recepción","grupo":"thin client"},{"nombre":"Zebra ZQ630 #1","grupo":"impresora"},{"nombre":"Pistola 5","grupo":"lector"}]}');
  assert (r->>'nuevos')::int = 4, 'importar disp: ' || r;
  assert (select count(*) from registro.dispositivos where grupo = 'Ordenador') = 1, 'grupo ordenador';
  assert (select count(*) from registro.dispositivos where grupo = 'Impresora') = 1, 'grupo impresora';
  assert (select count(*) from registro.dispositivos where grupo = 'Móvil / lector') = 1, 'grupo lector';
  assert (select grupo from registro.personas where nombre = 'Persona B') = 'Jefe', 'grupo jefe';

  select id into d1 from registro.dispositivos where nombre = '#1 Transpaleta Linde';
  select id into d2 from registro.dispositivos where nombre = 'Pistola 5';

  -- coger
  r := public.rd_accion('clave-de-prueba-123', 'coger', jsonb_build_object('dispositivo_id', d1, 'persona', 'persona a', 'nota', 'turno mañana'));
  assert (r->>'ok')::boolean, 'coger: ' || r;
  assert (select tiene from registro.dispositivos where id = d1) = 'Persona A', 'tiene canónico';
  -- otra vez la misma persona: no duplica
  r := public.rd_accion('clave-de-prueba-123', 'coger', jsonb_build_object('dispositivo_id', d1, 'persona', 'Persona A'));
  assert (r->>'ya')::boolean, 'ya lo tenia';
  assert (select count(*) from registro.movimientos) = 1, 'sin duplicados';
  -- otra persona sin forzar: ocupado
  r := public.rd_accion('clave-de-prueba-123', 'coger', jsonb_build_object('dispositivo_id', d1, 'persona', 'Persona B'));
  assert r->>'codigo' = 'ocupado' and r->>'tiene' = 'Persona A', 'ocupado: ' || r;
  assert (select count(*) from registro.movimientos) = 1, 'ocupado no registra';
  -- forzar: auto-dejar + coger
  r := public.rd_accion('clave-de-prueba-123', 'coger', jsonb_build_object('dispositivo_id', d1, 'persona', 'Persona B', 'forzar', true));
  assert (r->>'ok')::boolean, 'forzar: ' || r;
  assert (select count(*) from registro.movimientos) = 3, 'forzar registra 2';
  assert (select automatico from registro.movimientos where accion = 'dejar') , 'dejar automatico';
  assert (select persona from registro.movimientos where accion = 'dejar') = 'Persona A', 'el auto-dejar es de la primera persona';
  assert (select tiene from registro.dispositivos where id = d1) = 'Persona B', 'ahora Dani';
  -- persona no existente
  r := public.rd_accion('clave-de-prueba-123', 'coger', jsonb_build_object('dispositivo_id', d2, 'persona', 'Nadie'));
  assert r->>'codigo' = 'error', 'persona inexistente';
  -- dejar por otra persona
  r := public.rd_accion('clave-de-prueba-123', 'dejar', jsonb_build_object('dispositivo_id', d1, 'persona', 'Persona A', 'nota', 'en la carga 3'));
  assert (r->>'ok')::boolean, 'dejar: ' || r;
  assert (select persona || '/' || coalesce(por,'-') from registro.movimientos where accion='dejar' order by id desc limit 1) = 'Persona B/Persona A', 'dejar atribuido al que lo tenia';
  assert (select tiene is null and desde is null from registro.dispositivos where id = d1), 'libre';
  r := public.rd_accion('clave-de-prueba-123', 'dejar', jsonb_build_object('dispositivo_id', d1, 'persona', 'Persona A'));
  assert (r->>'ya')::boolean, 'ya libre';

  -- historial
  r := public.rd_accion('clave-de-prueba-123', 'historial', '{"limite":2}');
  assert jsonb_array_length(r->'filas') = 2 and (r->>'mas')::boolean, 'historial paginado: ' || r;
  r := public.rd_accion('clave-de-prueba-123', 'historial', '{"limite":2,"desplazamiento":2}');
  assert jsonb_array_length(r->'filas') = 2 and not (r->>'mas')::boolean, 'historial pagina 2: ' || r;
  r := public.rd_accion('clave-de-prueba-123', 'historial', jsonb_build_object('persona','persona b','accion','coger'));
  assert jsonb_array_length(r->'filas') = 1, 'filtro persona+accion: ' || r;
  r := public.rd_accion('clave-de-prueba-123', 'historial', jsonb_build_object('dispositivo_id', d2));
  assert jsonb_array_length(r->'filas') = 0, 'filtro dispositivo sin movimientos';
  r := public.rd_accion('clave-de-prueba-123', 'historial', jsonb_build_object('desde', to_char(now() at time zone 'Europe/Madrid','YYYY-MM-DD'), 'hasta', to_char(now() at time zone 'Europe/Madrid','YYYY-MM-DD')));
  assert jsonb_array_length(r->'filas') = 4, 'filtro fechas hoy: ' || r;
  r := public.rd_accion('clave-de-prueba-123', 'historial', '{"desde":"2020-01-01","hasta":"2020-01-02"}');
  assert jsonb_array_length(r->'filas') = 0, 'filtro fechas pasado';
  r := public.rd_accion('clave-de-prueba-123', 'historial', '{"desde":"no-es-fecha"}');
  assert r->>'error' = 'Datos no válidos.', 'fecha mala: ' || r;
  r := public.rd_accion('clave-de-prueba-123', 'exportar', '{"limite":5000}');
  assert jsonb_array_length(r->'filas') = 4, 'exportar';

  -- ajustes
  r := public.rd_accion('clave-de-prueba-123', 'guardar_dispositivo', '{"nombre":"#1 transpaleta linde"}');
  assert r->>'error' = 'Ya hay un dispositivo con ese nombre.', 'duplicado: ' || r;
  r := public.rd_accion('clave-de-prueba-123', 'guardar_dispositivo', jsonb_build_object('id', d2, 'nombre', 'Pistola 5 (nueva)', 'grupo', 'Móvil / lector', 'serie', '123'));
  assert (r->>'ok')::boolean and (select nombre from registro.dispositivos where id = d2) = 'Pistola 5 (nueva)', 'renombrar';
  -- archivar con alguien dentro
  perform public.rd_accion('clave-de-prueba-123', 'coger', jsonb_build_object('dispositivo_id', d2, 'persona', 'Persona A'));
  r := public.rd_accion('clave-de-prueba-123', 'archivar_dispositivo', jsonb_build_object('id', d2, 'activo', false));
  assert r->>'error' like 'Lo tiene Persona A%', 'no archiva en uso: ' || r;
  perform public.rd_accion('clave-de-prueba-123', 'dejar', jsonb_build_object('dispositivo_id', d2, 'persona', 'Persona A'));
  r := public.rd_accion('clave-de-prueba-123', 'archivar_dispositivo', jsonb_build_object('id', d2, 'activo', false));
  assert (r->>'ok')::boolean, 'archiva';
  r := public.rd_accion('clave-de-prueba-123', 'coger', jsonb_build_object('dispositivo_id', d2, 'persona', 'Persona A'));
  assert r->>'error' = 'No encuentro ese dispositivo.', 'archivado no se coge';
  -- renombrar persona que tiene un dispositivo
  perform public.rd_accion('clave-de-prueba-123', 'coger', jsonb_build_object('dispositivo_id', d1, 'persona', 'Persona A'));
  r := public.rd_accion('clave-de-prueba-123', 'guardar_persona', jsonb_build_object('id', (select id from registro.personas where nombre = 'Persona A'), 'nombre', 'Persona A bis', 'grupo', 'Operario'));
  assert (select tiene from registro.dispositivos where id = d1) = 'Persona A bis', 'renombrar persona arrastra tenencia: ' || r;

  -- clave
  r := public.rd_accion('clave-de-prueba-123', 'cambiar_clave', '{"nueva":"corta"}');
  assert r->>'error' like 'La clave nueva%', 'clave corta';
  r := public.rd_accion('clave-de-prueba-123', 'cambiar_clave', '{"nueva":"otra-clave-larga-456"}');
  assert (r->>'ok')::boolean, 'cambiar clave';
  r := public.rd_accion('clave-de-prueba-123', 'estado'); assert r->>'codigo' = 'clave', 'la vieja ya no vale';
  r := public.rd_accion('otra-clave-larga-456', 'estado'); assert (r->>'ok')::boolean and jsonb_array_length(r->'dispositivos') = 4, 'la nueva sí';

  -- bloqueo por intentos
  for n in 1..55 loop perform public.rd_accion('x' || n, 'estado'); end loop;
  r := public.rd_accion('otra-clave-larga-456', 'estado');
  assert r->>'codigo' = 'bloqueado', 'bloqueo: ' || r;
  delete from registro.fallos;
  r := public.rd_accion('otra-clave-larga-456', 'estado'); assert (r->>'ok')::boolean, 'desbloqueado';
  raise notice 'TODAS LAS PRUEBAS SQL OK';
end $t$;

-- permisos: anon/authenticated no pueden nada
set role anon;
do $t$ begin
  begin perform public.rd_accion('x','estado'); raise exception 'anon pudo ejecutar rd_accion'; exception when insufficient_privilege then null; end;
  begin perform 1 from registro.personas; raise exception 'anon pudo leer personas'; exception when insufficient_privilege then null; end;
  begin perform registro.estado(); raise exception 'anon pudo ejecutar registro.estado'; exception when insufficient_privilege then null; end;
  raise notice 'anon bloqueado OK';
end $t$;
reset role;
set role authenticated;
do $t$ begin
  begin perform public.rd_accion('x','estado'); raise exception 'authenticated pudo ejecutar rd_accion'; exception when insufficient_privilege then null; end;
  begin perform 1 from registro.movimientos; raise exception 'authenticated pudo leer'; exception when insufficient_privilege then null; end;
  raise notice 'authenticated bloqueado OK';
end $t$;
reset role;
set role service_role;
do $t$ declare r jsonb; begin
  r := public.rd_accion('otra-clave-larga-456','comprobar'); assert (r->>'ok')::boolean, 'service_role puede ejecutar';
  begin perform 1 from registro.personas; raise exception 'service_role leyó tablas directamente (no hace falta)'; exception when insufficient_privilege then null; end;
  raise notice 'service_role OK';
end $t$;
reset role;
