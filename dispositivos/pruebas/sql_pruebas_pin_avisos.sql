-- Pruebas de 003_pin_y_avisos.sql sobre una base vacía (nombres genéricos, sin datos reales).
-- Uso: createdb prueba && psql -d prueba -v ON_ERROR_STOP=1 -f dispositivos/pruebas/sql_pruebas_pin_avisos.sql
\set ON_ERROR_STOP on
do $$ begin
  if not exists (select 1 from pg_roles where rolname = 'anon') then create role anon nologin; end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then create role authenticated nologin; end if;
  if not exists (select 1 from pg_roles where rolname = 'service_role') then create role service_role nologin bypassrls; end if;
end $$;
create schema if not exists extensions;
\i dispositivos/sql/001_registro_dispositivos.sql
\i dispositivos/sql/003_pin_y_avisos.sql
\i dispositivos/sql/003_pin_y_avisos.sql
update registro.config set clave_hash = extensions.crypt('clave-de-prueba-123', extensions.gen_salt('bf', 10)) where id = 1;

do $t$
declare r jsonb; c text := 'clave-de-prueba-123'; d1 uuid; v_id bigint; n int;
begin
  perform public.rd_accion(c, 'importar_personas', '{"lineas":[{"nombre":"Ana","grupo":"jefe"},{"nombre":"Beto","grupo":"operario"}]}');
  r := public.rd_accion(c, 'importar_dispositivos', '{"lineas":[{"nombre":"#1 Carretilla","grupo":"Máquina"},{"nombre":"Móvil 2","grupo":"móvil"}]}');
  d1 := (select id from registro.dispositivos where nombre = '#1 Carretilla');

  -- sin PIN puesto: no se exige y estado dice con_pin=false
  assert (public.rd_accion(c, 'estado')->>'con_pin')::boolean = false, 'con_pin falso al principio';
  assert (public.rd_accion(c, 'historial')->>'ok')::boolean, 'sin PIN puesto el historial va';

  -- poner PIN: solo 4 números
  r := public.rd_accion(c, 'cambiar_pin', '{"nueva":"12a4"}'); assert r->>'codigo' = 'error', 'pin no numérico: ' || r;
  r := public.rd_accion(c, 'cambiar_pin', '{"nueva":"123"}');  assert r->>'codigo' = 'error', 'pin corto';
  r := public.rd_accion(c, 'cambiar_pin', '{"nueva":"4821"}'); assert (r->>'ok')::boolean and (r->>'con_pin')::boolean, 'pin puesto: ' || r;

  -- con PIN: lo protegido exige el PIN; coger/dejar/avisar/estado no
  r := public.rd_accion(c, 'historial');                           assert r->>'codigo' = 'pin', 'historial sin pin';
  r := public.rd_accion(c, 'historial', '{"pin":"0000"}');          assert r->>'codigo' = 'pin', 'historial pin malo';
  r := public.rd_accion(c, 'historial', '{"pin":4821}');            assert r->>'codigo' = 'pin', 'pin como número no vale';
  r := public.rd_accion(c, 'historial', '{"pin":"4821"}');          assert (r->>'ok')::boolean, 'historial pin bueno';
  r := public.rd_accion(c, 'exportar', '{"pin":"4821"}');           assert (r->>'ok')::boolean, 'exportar';
  r := public.rd_accion(c, 'guardar_persona', '{"nombre":"Cris"}'); assert r->>'codigo' = 'pin', 'ajustes sin pin';
  r := public.rd_accion(c, 'cambiar_clave', '{"nueva":"otraclave123"}'); assert r->>'codigo' = 'pin', 'cambiar clave sin pin';
  r := public.rd_accion(c, 'avisos');                               assert r->>'codigo' = 'pin', 'avisos sin pin';
  r := public.rd_accion(c, 'coger', jsonb_build_object('dispositivo_id', d1, 'persona', 'Beto')); assert (r->>'ok')::boolean, 'coger libre';
  r := public.rd_accion(c, 'estado');                               assert (r->>'ok')::boolean, 'estado libre';
  r := public.rd_accion(c, 'comprobar_pin', '{"pin":"4821"}');      assert (r->>'ok')::boolean, 'comprobar_pin ok';

  -- avisos: cualquiera avisa; salen en estado; solo con PIN se resuelven
  r := public.rd_accion(c, 'avisar', jsonb_build_object('dispositivo_id', d1, 'persona', 'Beto', 'texto', ''));  assert r->>'codigo' = 'error', 'aviso vacío';
  r := public.rd_accion(c, 'avisar', jsonb_build_object('dispositivo_id', d1, 'persona', 'Nadie', 'texto', 'x')); assert r->>'codigo' = 'error', 'aviso persona desconocida';
  r := public.rd_accion(c, 'avisar', jsonb_build_object('dispositivo_id', d1, 'persona', 'Beto', 'texto', 'Falta agua en la batería'));
  assert (r->>'ok')::boolean and jsonb_array_length(r->'avisos') = 1 and r->'avisos'->0->>'por' = 'Beto', 'aviso creado: ' || r;
  v_id := (r->'avisos'->0->>'id')::bigint;
  r := public.rd_accion(c, 'resolver_aviso', jsonb_build_object('id', v_id, 'persona', 'Ana')); assert r->>'codigo' = 'pin', 'resolver sin pin';
  r := public.rd_accion(c, 'avisos', '{"pin":"4821"}'); assert jsonb_array_length(r->'avisos') = 1, 'lista de avisos';
  r := public.rd_accion(c, 'resolver_aviso', jsonb_build_object('id', v_id, 'persona', 'Ana', 'nota', 'Rellenada', 'pin', '4821'));
  assert (r->>'ok')::boolean and jsonb_array_length(r->'avisos') = 0, 'aviso resuelto: ' || r;
  r := public.rd_accion(c, 'resolver_aviso', jsonb_build_object('id', v_id, 'persona', 'Ana', 'pin', '4821')); assert r->>'codigo' = 'error', 'doble resolución';
  r := public.rd_accion(c, 'avisos', '{"pin":"4821"}');
  assert r->'avisos'->0->>'resuelto_por' = 'Ana' and r->'avisos'->0->>'resuelto_nota' = 'Rellenada', 'historial de avisos';
  for n in 1..5 loop perform public.rd_accion(c, 'avisar', jsonb_build_object('dispositivo_id', d1, 'persona', 'Beto', 'texto', 'a' || n)); end loop;
  r := public.rd_accion(c, 'avisar', jsonb_build_object('dispositivo_id', d1, 'persona', 'Beto', 'texto', 'sexto'));
  assert r->>'codigo' = 'error', 'máximo 5 avisos abiertos por dispositivo';

  -- límite de intentos del PIN: 10 fallos en 10 minutos (los de arriba ya cuentan algunos)
  for n in 1..12 loop perform public.rd_accion(c, 'historial', '{"pin":"9999"}'); end loop;
  r := public.rd_accion(c, 'historial', '{"pin":"4821"}');
  assert r->>'codigo' = 'pin' and (r->>'bloqueado')::boolean, 'PIN bloqueado tras muchos fallos: ' || r;
  r := public.rd_accion(c, 'estado'); assert (r->>'ok')::boolean, 'el bloqueo del PIN no bloquea Ahora';
  delete from registro.fallos_pin;
  r := public.rd_accion(c, 'historial', '{"pin":"4821"}'); assert (r->>'ok')::boolean, 'desbloqueo al pasar el tiempo';
  -- cambiar el PIN con el PIN
  r := public.rd_accion(c, 'cambiar_pin', '{"nueva":"7305","pin":"4821"}'); assert (r->>'ok')::boolean, 'cambiar pin';
  r := public.rd_accion(c, 'historial', '{"pin":"4821"}'); assert r->>'codigo' = 'pin', 'el PIN viejo ya no vale';
  r := public.rd_accion(c, 'historial', '{"pin":"7305"}'); assert (r->>'ok')::boolean, 'el PIN nuevo vale';
  raise notice 'PRUEBAS PIN Y AVISOS OK';
end $t$;

do $t$ begin
  assert not has_function_privilege('anon', 'public.rd_accion(text,text,jsonb)', 'execute'), 'anon no ejecuta';
  assert not has_function_privilege('authenticated', 'public.rd_accion(text,text,jsonb)', 'execute'), 'authenticated no ejecuta';
  assert has_function_privilege('service_role', 'public.rd_accion(text,text,jsonb)', 'execute'), 'service_role sí';
  assert not has_table_privilege('anon', 'registro.avisos', 'select'), 'anon no lee avisos';
  assert (select relrowsecurity from pg_class where oid = 'registro.avisos'::regclass), 'RLS en avisos';
  raise notice 'PERMISOS OK';
end $t$;
