-- Pruebas de 007_mejoras.sql sobre una base vacía (nombres genéricos, sin datos reales).
-- Uso: createdb prueba && psql -d prueba -v ON_ERROR_STOP=1 -f dispositivos/pruebas/sql_pruebas_mejoras.sql
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
\i dispositivos/sql/007_mejoras.sql
update registro.config set clave_hash = extensions.crypt('clave-de-prueba-123', extensions.gen_salt('bf', 10)) where id = 1;

do $t$
declare r jsonb; c text := 'clave-de-prueba-123'; d1 uuid; d2 uuid; n int; t1 timestamptz; t2 timestamptz; v jsonb;
begin
  perform public.rd_accion(c, 'importar_personas', '{"lineas":[{"nombre":"Ana","grupo":"jefe"},{"nombre":"Beto","grupo":"operario"},{"nombre":"Cleo","grupo":"operario"}]}');
  perform public.rd_accion(c, 'importar_dispositivos', '{"lineas":[{"nombre":"#1 Carretilla","grupo":"Máquina"},{"nombre":"Móvil 2","grupo":"móvil"},{"nombre":"#3 Apilador","grupo":"Máquina"}]}');
  d1 := (select id from registro.dispositivos where nombre = '#1 Carretilla');
  d2 := (select id from registro.dispositivos where nombre = 'Móvil 2');

  -- estado: cada dispositivo trae «fuera» (falso al principio) y el resto del contrato sigue igual
  r := public.rd_accion(c, 'estado');
  assert (r->'dispositivos'->0) ? 'fuera' and (r->'dispositivos'->0) ? 'fuera_motivo' and (r->'dispositivos'->0) ? 'fuera_desde', 'estado trae fuera';
  assert not exists (select 1 from jsonb_array_elements(r->'dispositivos') e where (e->>'fuera')::boolean), 'nadie fuera al principio';
  assert r ? 'avisos' and r ? 'con_pin' and r ? 'personas' and r ? 'ahora', 'el contrato de estado sigue';

  -- ── pasar ──
  r := public.rd_accion(c, 'pasar', jsonb_build_object('dispositivo_id', d1, 'persona', 'Ana', 'para', 'Beto'));
  assert r->>'codigo' = 'error' and r->>'error' like 'Ahora no lo tiene nadie%', 'pasar sin dueño: ' || r;
  perform public.rd_accion(c, 'coger', jsonb_build_object('dispositivo_id', d1, 'persona', 'Ana'));
  r := public.rd_accion(c, 'pasar', jsonb_build_object('dispositivo_id', d1, 'persona', 'Ana', 'para', 'Nadie'));
  assert r->>'codigo' = 'error' and r->>'error' like 'Elige a quién%', 'pasar a alguien que no existe: ' || r;
  r := public.rd_accion(c, 'pasar', jsonb_build_object('dispositivo_id', d1, 'persona', 'Zzz', 'para', 'Beto'));
  assert r->>'codigo' = 'error' and r->>'error' like 'Elige quién eres%', 'pasar sin quién eres: ' || r;
  r := public.rd_accion(c, 'pasar', jsonb_build_object('dispositivo_id', d1, 'persona', 'Ana', 'para', 'ana'));
  assert (r->>'ok')::boolean and (r->>'ya')::boolean, 'pasar a quien ya lo tiene es «ya»: ' || r;
  r := public.rd_accion(c, 'pasar', jsonb_build_object('dispositivo_id', d1, 'persona', 'Ana', 'para', 'Beto', 'nota', 'turno de tarde'));
  assert (r->>'ok')::boolean and not (r ? 'ya'), 'pasar a Beto: ' || r;
  assert (select tiene from registro.dispositivos where id = d1) = 'Beto', 'ahora lo tiene Beto';
  select ts into t1 from registro.movimientos where dispositivo_id = d1 and accion = 'dejar' and automatico order by id desc limit 1;
  select ts into t2 from registro.movimientos where dispositivo_id = d1 and accion = 'coger' order by id desc limit 1;
  assert t1 = t2 and (select desde from registro.dispositivos where id = d1) = t2, 'el dejar y el coger del traspaso llevan la misma hora';
  assert (select persona from registro.movimientos where dispositivo_id = d1 and accion = 'dejar' order by id desc limit 1) = 'Ana', 'Ana lo deja';
  assert (select nota from registro.movimientos where dispositivo_id = d1 and accion = 'dejar' order by id desc limit 1) = 'Pasa a Beto', 'nota Pasa a';
  assert (select nota from registro.movimientos where dispositivo_id = d1 and accion = 'coger' order by id desc limit 1) = 'turno de tarde', 'nota del traspaso';
  assert (select por from registro.movimientos where dispositivo_id = d1 and accion = 'dejar' order by id desc limit 1) is null, 'el que pasa lo registra: sin «por»';
  -- reenvío de la misma petición: idempotente
  r := public.rd_accion(c, 'pasar', jsonb_build_object('dispositivo_id', d1, 'persona', 'Ana', 'para', 'Beto'));
  assert (r->>'ok')::boolean and (r->>'ya')::boolean, 'reenvío del traspaso: ya';
  -- lo registra un tercero
  r := public.rd_accion(c, 'pasar', jsonb_build_object('dispositivo_id', d1, 'persona', 'Cleo', 'para', 'Ana'));
  assert (select por from registro.movimientos where dispositivo_id = d1 and accion = 'dejar' order by id desc limit 1) = 'Cleo', 'un tercero lo registra: «por» = Cleo';
  assert (select por from registro.movimientos where dispositivo_id = d1 and accion = 'coger' order by id desc limit 1) = 'Cleo', 'y el coger también';
  perform public.rd_accion(c, 'dejar', jsonb_build_object('dispositivo_id', d1, 'persona', 'Ana'));

  -- «tiene» / «de»: no se le quita a otra persona lo que ahora tiene (pantalla desfasada o cola reenviada)
  perform public.rd_accion(c, 'coger', jsonb_build_object('dispositivo_id', d1, 'persona', 'Beto'));
  r := public.rd_accion(c, 'dejar', jsonb_build_object('dispositivo_id', d1, 'persona', 'Ana', 'tiene', 'Cleo'));
  assert r->>'ok' = 'false' and r->>'codigo' = 'cambio' and r->>'error' like 'Ahora lo tiene Beto%', 'dejar con otro dueño: ' || r;
  assert (select tiene from registro.dispositivos where id = d1) = 'Beto', 'sigue siendo de Beto';
  assert (r->'dispositivos') is not null, 'la respuesta trae el estado para refrescar';
  r := public.rd_accion(c, 'pasar', jsonb_build_object('dispositivo_id', d1, 'persona', 'Ana', 'para', 'Cleo', 'de', 'Ana'));
  assert r->>'codigo' = 'cambio' and (select tiene from registro.dispositivos where id = d1) = 'Beto', 'pasar con otro dueño: ' || r;
  r := public.rd_accion(c, 'pasar', jsonb_build_object('dispositivo_id', d1, 'persona', 'Beto', 'para', 'Cleo', 'de', 'beto'));
  assert (r->>'ok')::boolean and (select tiene from registro.dispositivos where id = d1) = 'Cleo', 'pasar con «de» correcto: ' || r;
  r := public.rd_accion(c, 'dejar', jsonb_build_object('dispositivo_id', d1, 'persona', 'Cleo', 'tiene', 'cleo'));
  assert (r->>'ok')::boolean and (select tiene from registro.dispositivos where id = d1) is null, 'dejar con «tiene» correcto: ' || r;
  r := public.rd_accion(c, 'dejar', jsonb_build_object('dispositivo_id', d1, 'persona', 'Cleo', 'tiene', 'Cleo'));
  assert (r->>'ya')::boolean, 'dejar algo ya libre sigue siendo «ya»';

  -- cogerlo forzando solo vale si sigue en manos de quien se veía
  perform public.rd_accion(c, 'coger', jsonb_build_object('dispositivo_id', d1, 'persona', 'Beto'));
  r := public.rd_accion(c, 'coger', jsonb_build_object('dispositivo_id', d1, 'persona', 'Cleo', 'forzar', true, 'tiene', 'Ana'));
  assert r->>'codigo' = 'cambio' and (select tiene from registro.dispositivos where id = d1) = 'Beto', 'coger forzando con otro dueño: ' || r;
  r := public.rd_accion(c, 'coger', jsonb_build_object('dispositivo_id', d1, 'persona', 'Cleo', 'forzar', true, 'tiene', 'beto'));
  assert (r->>'ok')::boolean and (select tiene from registro.dispositivos where id = d1) = 'Cleo', 'coger forzando con el dueño correcto: ' || r;
  perform public.rd_accion(c, 'dejar', jsonb_build_object('dispositivo_id', d1, 'persona', 'Cleo'));

  -- ── fuera de servicio (lleva PIN) ──
  r := public.rd_accion(c, 'cambiar_pin', '{"nueva":"4821"}');
  r := public.rd_accion(c, 'fuera_servicio', jsonb_build_object('dispositivo_id', d1, 'persona', 'Ana', 'fuera', true, 'motivo', 'Frena mal'));
  assert r->>'codigo' = 'pin', 'fuera de servicio sin PIN: ' || r;
  r := public.rd_accion(c, 'fuera_servicio', jsonb_build_object('dispositivo_id', d1, 'persona', 'Ana', 'fuera', true, 'motivo', 'Frena mal', 'pin', '0000'));
  assert r->>'codigo' = 'pin', 'PIN malo';
  r := public.rd_accion(c, 'fuera_servicio', jsonb_build_object('dispositivo_id', d1, 'persona', 'Ana', 'fuera', true, 'motivo', 'ab', 'pin', '4821'));
  assert r->>'codigo' = 'error' and r->>'error' like 'Escribe el motivo%', 'motivo corto: ' || r;
  r := public.rd_accion(c, 'fuera_servicio', jsonb_build_object('dispositivo_id', d1, 'persona', 'Nadie', 'fuera', true, 'motivo', 'Frena mal', 'pin', '4821'));
  assert r->>'codigo' = 'error' and r->>'error' like 'Elige quién eres%', 'sin persona';
  r := public.rd_accion(c, 'fuera_servicio', jsonb_build_object('dispositivo_id', d1, 'persona', 'Ana', 'fuera', true, 'motivo', 'Frena mal', 'pin', '4821'));
  assert (r->>'ok')::boolean, 'poner fuera de servicio: ' || r;
  assert (select (e->>'fuera')::boolean and e->>'fuera_motivo' = 'Frena mal' and e->>'fuera_desde' is not null
            from jsonb_array_elements(r->'dispositivos') e where e->>'id' = d1::text), 'estado la marca fuera';
  r := public.rd_accion(c, 'coger', jsonb_build_object('dispositivo_id', d1, 'persona', 'Beto'));
  assert r->>'ok' = 'false' and r->>'codigo' = 'fuera' and r->>'error' like 'Está fuera de servicio: Frena mal%', 'no se puede coger: ' || r;
  assert (r->'dispositivos') is not null, 'la respuesta de «fuera» trae el estado para refrescar';
  r := public.rd_accion(c, 'coger', jsonb_build_object('dispositivo_id', d1, 'persona', 'Beto', 'forzar', true));
  assert r->>'codigo' = 'fuera', 'ni forzando';
  assert (select tiene from registro.dispositivos where id = d1) is null, 'sigue libre';
  r := public.rd_accion(c, 'fuera_servicio', jsonb_build_object('dispositivo_id', d1, 'persona', 'Ana', 'fuera', true, 'motivo', 'Otra vez', 'pin', '4821'));
  assert (r->>'ya')::boolean, 'ponerlo fuera dos veces: ya';
  assert (select count(*) from registro.fuera_log where dispositivo_id = d1) = 1, 'un solo registro';
  -- archivar no se ve afectado y un dispositivo fuera sigue saliendo en el estado
  r := public.rd_accion(c, 'fuera_servicio', jsonb_build_object('dispositivo_id', d1, 'persona', 'Ana', 'fuera', false, 'motivo', 'Cambiadas las pastillas', 'pin', '4821'));
  assert (r->>'ok')::boolean and not (select (e->>'fuera')::boolean from jsonb_array_elements(r->'dispositivos') e where e->>'id' = d1::text), 'volver a ponerlo en servicio';
  assert (select fuera_motivo is null and fuera_desde is null and fuera_por is null from registro.dispositivos where id = d1), 'se limpia el motivo';
  r := public.rd_accion(c, 'fuera_servicio', jsonb_build_object('dispositivo_id', d1, 'persona', 'Ana', 'fuera', false, 'pin', '4821'));
  assert (r->>'ya')::boolean, 'volver a ponerlo en servicio dos veces: ya';
  assert (select count(*) from registro.fuera_log where dispositivo_id = d1 and accion = 'servicio') = 1, 'registro de servicio';
  r := public.rd_accion(c, 'coger', jsonb_build_object('dispositivo_id', d1, 'persona', 'Beto'));
  assert (r->>'ok')::boolean, 'ya se puede coger: ' || r;
  -- fuera mientras alguien lo tiene: sigue siendo suyo, nadie más lo coge ni se lo pasan
  perform public.rd_accion(c, 'fuera_servicio', jsonb_build_object('dispositivo_id', d1, 'persona', 'Ana', 'fuera', true, 'motivo', 'Se ha roto', 'pin', '4821'));
  r := public.rd_accion(c, 'pasar', jsonb_build_object('dispositivo_id', d1, 'persona', 'Beto', 'para', 'Cleo'));
  assert r->>'codigo' = 'fuera' and (select tiene from registro.dispositivos where id = d1) = 'Beto', 'tampoco se puede pasar: ' || r;
  r := public.rd_accion(c, 'dejar', jsonb_build_object('dispositivo_id', d1, 'persona', 'Beto'));
  assert (r->>'ok')::boolean, 'pero sí se puede dejar';
  perform public.rd_accion(c, 'fuera_servicio', jsonb_build_object('dispositivo_id', d1, 'persona', 'Ana', 'fuera', false, 'pin', '4821'));

  -- ── «cuando»: movimientos hechos sin conexión ──
  r := public.rd_accion(c, 'coger', jsonb_build_object('dispositivo_id', d2, 'persona', 'Cleo', 'cuando', to_char(clock_timestamp() - interval '3 hours', 'YYYY-MM-DD"T"HH24:MI:SS.MSOF')));
  assert (r->>'ok')::boolean, 'coger con cuando: ' || r;
  t1 := (select desde from registro.dispositivos where id = d2);
  assert t1 between clock_timestamp() - interval '3 hours 1 minute' and clock_timestamp() - interval '2 hours 59 minutes', 'desde = la hora del móvil: ' || t1;
  -- un «dejar» con hora anterior al coger se queda en la hora del coger (nunca un uso negativo)
  r := public.rd_accion(c, 'dejar', jsonb_build_object('dispositivo_id', d2, 'persona', 'Cleo', 'cuando', to_char(clock_timestamp() - interval '5 hours', 'YYYY-MM-DD"T"HH24:MI:SS.MSOF')));
  assert (r->>'ok')::boolean, 'dejar con cuando anterior';
  assert (select ts = desde from registro.movimientos where dispositivo_id = d2 and accion = 'dejar' order by id desc limit 1), 'el dejar no es anterior al coger';
  -- futuro, viejo, no texto o basura: se usa la hora del servidor, sin error
  perform public.rd_accion(c, 'coger', jsonb_build_object('dispositivo_id', d2, 'persona', 'Cleo', 'cuando', to_char(clock_timestamp() + interval '1 day', 'YYYY-MM-DD"T"HH24:MI:SSOF')));
  assert (select desde from registro.dispositivos where id = d2) > clock_timestamp() - interval '1 minute', 'una hora futura se ignora';
  perform public.rd_accion(c, 'dejar', jsonb_build_object('dispositivo_id', d2, 'persona', 'Cleo'));
  perform public.rd_accion(c, 'coger', jsonb_build_object('dispositivo_id', d2, 'persona', 'Cleo', 'cuando', to_char(clock_timestamp() - interval '3 days', 'YYYY-MM-DD"T"HH24:MI:SSOF')));
  assert (select desde from registro.dispositivos where id = d2) > clock_timestamp() - interval '1 minute', 'una hora de hace más de 2 días se ignora';
  perform public.rd_accion(c, 'dejar', jsonb_build_object('dispositivo_id', d2, 'persona', 'Cleo'));
  r := public.rd_accion(c, 'coger', jsonb_build_object('dispositivo_id', d2, 'persona', 'Cleo', 'cuando', 12345));
  assert (r->>'ok')::boolean, 'cuando que no es texto: se ignora';
  perform public.rd_accion(c, 'dejar', jsonb_build_object('dispositivo_id', d2, 'persona', 'Cleo'));
  r := public.rd_accion(c, 'coger', jsonb_build_object('dispositivo_id', d2, 'persona', 'Cleo', 'cuando', 'ayer por la tarde'));
  assert (r->>'ok')::boolean, 'cuando basura: se ignora sin error: ' || r;
  perform public.rd_accion(c, 'dejar', jsonb_build_object('dispositivo_id', d2, 'persona', 'Cleo'));
  -- la línea de tiempo de un dispositivo nunca retrocede
  perform public.rd_accion(c, 'coger', jsonb_build_object('dispositivo_id', d2, 'persona', 'Beto'));
  r := public.rd_accion(c, 'dejar', jsonb_build_object('dispositivo_id', d2, 'persona', 'Beto'));
  perform public.rd_accion(c, 'coger', jsonb_build_object('dispositivo_id', d2, 'persona', 'Cleo', 'cuando', to_char(clock_timestamp() - interval '1 hour', 'YYYY-MM-DD"T"HH24:MI:SS.MSOF')));
  assert (select desde from registro.dispositivos where id = d2) >= (select max(ts) from registro.movimientos where dispositivo_id = d2 and persona = 'Beto'),
         'un coger atrasado no se cuela antes del último movimiento';
  perform public.rd_accion(c, 'dejar', jsonb_build_object('dispositivo_id', d2, 'persona', 'Cleo'));

  -- ── avisos: sin duplicar un reenvío ──
  r := public.rd_accion(c, 'avisar', jsonb_build_object('dispositivo_id', d1, 'persona', 'Beto', 'texto', 'Falta agua'));
  assert (r->>'ok')::boolean and jsonb_array_length(r->'avisos') = 1, 'aviso 1';
  r := public.rd_accion(c, 'avisar', jsonb_build_object('dispositivo_id', d1, 'persona', 'Beto', 'texto', 'Falta agua'));
  assert (r->>'ok')::boolean and (r->>'ya')::boolean and jsonb_array_length(r->'avisos') = 1, 'el reenvío no duplica: ' || r;
  r := public.rd_accion(c, 'avisar', jsonb_build_object('dispositivo_id', d1, 'persona', 'Cleo', 'texto', 'Falta agua'));
  assert jsonb_array_length(r->'avisos') = 2, 'otro autor sí';
  r := public.rd_accion(c, 'avisar', jsonb_build_object('dispositivo_id', d1, 'persona', 'Beto', 'texto', 'Frena mal', 'cuando', to_char(clock_timestamp() - interval '2 hours', 'YYYY-MM-DD"T"HH24:MI:SS.MSOF')));
  assert jsonb_array_length(r->'avisos') = 3, 'otro texto sí';
  assert (select ts < clock_timestamp() - interval '119 minutes' from registro.avisos where texto = 'Frena mal'), 'el aviso lleva la hora del móvil';

  -- ── estadísticas (lleva PIN) ──
  delete from registro.movimientos; update registro.dispositivos set tiene = null, desde = null;
  r := public.rd_accion(c, 'estadisticas', '{}');
  assert r->>'codigo' = 'pin', 'estadísticas sin PIN: ' || r;
  r := public.rd_accion(c, 'estadisticas', '{"pin":"4821"}');
  assert (r->>'ok')::boolean and (r->'resumen'->>'usos')::int = 0 and jsonb_array_length(r->'por_hora') = 24 and (r->>'dias')::int = 30, 'estadísticas vacías: ' || r;
  assert jsonb_array_length(r->'dispositivos') = 3, 'salen todos los dispositivos activos aunque no se usen';
  -- datos: Ana usa la carretilla 10 h (olvido), Beto el móvil 1 h, y un traspaso
  perform public.rd_accion(c, 'coger', jsonb_build_object('dispositivo_id', d1, 'persona', 'Ana', 'cuando', to_char(clock_timestamp() - interval '10 hours', 'YYYY-MM-DD"T"HH24:MI:SS.MSOF')));
  perform public.rd_accion(c, 'dejar', jsonb_build_object('dispositivo_id', d1, 'persona', 'Ana'));
  perform public.rd_accion(c, 'coger', jsonb_build_object('dispositivo_id', d2, 'persona', 'Beto', 'cuando', to_char(clock_timestamp() - interval '90 minutes', 'YYYY-MM-DD"T"HH24:MI:SS.MSOF')));
  perform public.rd_accion(c, 'pasar', jsonb_build_object('dispositivo_id', d2, 'persona', 'Beto', 'para', 'Cleo', 'cuando', to_char(clock_timestamp() - interval '30 minutes', 'YYYY-MM-DD"T"HH24:MI:SS.MSOF')));
  perform public.rd_accion(c, 'dejar', jsonb_build_object('dispositivo_id', d2, 'persona', 'Cleo'));
  r := public.rd_accion(c, 'estadisticas', '{"pin":"4821","dias":7}');
  v := r->'resumen';
  assert (v->>'usos')::int = 3, 'usos: ' || v;                                        -- Ana (1), Beto (1, por el traspaso), Cleo (1)
  assert (v->>'olvidos')::int = 1, 'un olvido de más de 8 h: ' || v;
  assert (v->>'traspasos')::int = 1, 'un traspaso: ' || v;
  assert (v->>'en_uso_ahora')::int = 0 and (v->>'fuera_ahora')::int = 0, 'nada en uso ni fuera';
  assert (v->>'paradas')::int >= 2, 'paradas contadas del registro: ' || v;
  assert (v->>'minutos')::int between 10 * 60 + 55 and 10 * 60 + 70 + 60, 'minutos sumados: ' || v;   -- 600 + 60 + 30 aprox.
  assert r->'personas'->0->>'persona' in ('Ana', 'Beto', 'Cleo') and jsonb_array_length(r->'personas') = 3, 'personas';
  assert (select (e->>'olvidos')::int from jsonb_array_elements(r->'personas') e where e->>'persona' = 'Ana') = 1, 'el olvido es de Ana';
  assert (select (e->>'usos')::int from jsonb_array_elements(r->'dispositivos') e where e->>'id' = d2::text) = 2, 'el móvil se usó 2 veces (Beto y Cleo)';
  assert (select (e->>'usos')::int from jsonb_array_elements(r->'dispositivos') e where e->>'nombre' = '#3 Apilador') = 0, 'el apilador, sin usar';
  assert (select e->>'dias_sin_uso' from jsonb_array_elements(r->'dispositivos') e where e->>'nombre' = '#3 Apilador') is null, 'el apilador nunca se usó: dias_sin_uso nulo';
  assert (select (e->>'dias_sin_uso')::int from jsonb_array_elements(r->'dispositivos') e where e->>'id' = d1::text) = 0, 'la carretilla se usó hoy';
  assert jsonb_array_length(r->'olvidos') = 1 and r->'olvidos'->0->>'persona' = 'Ana' and (r->'olvidos'->0->>'minutos')::int >= 590, 'lista de olvidos';
  assert (select sum(x::int) from jsonb_array_elements_text(r->'por_hora') x) = 3, 'horas punta: 3 «coger» (Ana, Beto y el del traspaso a Cleo)';
  assert (public.rd_accion(c, 'estadisticas', '{"pin":"4821","dias":0}')->>'dias')::int = 1, 'dias mínimo 1';
  assert (public.rd_accion(c, 'estadisticas', '{"pin":"4821","dias":9999}')->>'dias')::int = 365, 'dias máximo 365';
  assert (public.rd_accion(c, 'estadisticas', '{"pin":"4821","dias":"x"}')->>'codigo') = 'error', 'dias no numérico: error';
  -- un dispositivo archivado no sale
  perform public.rd_accion(c, 'archivar_dispositivo', jsonb_build_object('id', (select id from registro.dispositivos where nombre = '#3 Apilador'), 'activo', false, 'pin', '4821'));
  assert jsonb_array_length(public.rd_accion(c, 'estadisticas', '{"pin":"4821"}')->'dispositivos') = 2, 'archivado fuera de las estadísticas';

  -- ── permisos: nada público ──
  assert not has_function_privilege('anon', 'public.rd_accion(text,text,jsonb)', 'execute'), 'anon no ejecuta';
  assert not has_function_privilege('authenticated', 'public.rd_accion(text,text,jsonb)', 'execute'), 'authenticated no ejecuta';
  assert has_function_privilege('service_role', 'public.rd_accion(text,text,jsonb)', 'execute'), 'service_role sí';
  assert not has_function_privilege('anon', 'registro.a_pasar(jsonb)', 'execute'), 'a_pasar no es público';
  assert not has_function_privilege('anon', 'registro.a_estadisticas(jsonb)', 'execute'), 'a_estadisticas no es público';
  assert not has_table_privilege('anon', 'registro.fuera_log', 'select'), 'fuera_log no es público';
  assert (select relrowsecurity from pg_class where oid = 'registro.fuera_log'::regclass), 'fuera_log con RLS';
  assert public.rd_accion('clave-mala', 'pasar', '{}')->>'codigo' = 'clave', 'sin clave no hay traspaso';
  raise notice 'TODO OK (007)';
end $t$;
