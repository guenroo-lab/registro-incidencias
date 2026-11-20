-- ============================================================================
-- Registro de dispositivos (Anubis) · 009: cambiar el estado SIN PIN y con la RAZÓN siempre anotada.
--
-- · `cambiar_estado` y `fuera_servicio` ya NO piden el PIN de jefes: cualquier persona de la lista (jefe u operario) puede cambiar el
--   estado de un dispositivo o máquina (pulsación larga). Siguen pidiendo la clave de acceso (la del enlace) como todo lo demás.
--   `sync_centinela` (Centinela) y la zona de jefes (avisos, historial, ajustes, estadísticas) SIGUEN pidiendo el PIN.
-- · La razón (texto libre, hasta 200 letras) se guarda SIEMPRE, también al volver a operativo («qué se ha hecho») y al dar de baja.
--   Es obligatoria (mínimo 5 letras) para con fallo, averiado y en reparación, porque Centinela exige describir la avería.
--   Ahora queda en `cambios_estado.nota` de cada cambio (antes se perdía al volver a operativo).
-- · Centinela recibe la razón solo cuando el estado NO es operativo (como hasta ahora: una máquina OK no lleva observación).
-- · El Historial (pestaña de jefes) enseña también los cambios de estado, con su razón y quién los hizo (acción «estado»);
--   los hechos por Centinela salen como «Centinela».
-- · `estado()` trae además `estado_por` (quién marcó el estado actual) para enseñarlo junto a la razón.
--
-- Requiere 001, 003, 007 y 008. Se puede volver a ejecutar sin romper nada. No cambia tablas ni columnas.
-- Para deshacer: 009_deshacer.sql (y después volver a ejecutar 008_sincronizacion_centinela.sql).
-- ============================================================================

-- ── Estado: trae también quién marcó el estado actual ──────────────────────
create or replace function registro.estado() returns jsonb
language sql stable security definer set search_path = registro, pg_temp as $$
  select jsonb_build_object(
    'ok', true,
    'ahora', now(),
    'con_pin', coalesce((select pin_hash is not null from registro.config where id = 1), false),
    'dispositivos', coalesce((
      select jsonb_agg(jsonb_build_object('id', d.id, 'nombre', d.nombre, 'grupo', d.grupo, 'serie', d.serie,
                                          'activo', d.activo, 'tiene', d.tiene, 'desde', d.desde,
                                          'fuera', d.fuera, 'fuera_motivo', d.fuera_motivo, 'fuera_desde', d.fuera_desde,
                                          'estado', d.estado, 'estado_nota', d.estado_nota, 'estado_desde', d.estado_desde, 'estado_por', d.estado_por,
                                          'enlazado', d.origen is not null,
                                          'pendiente_cs', exists (select 1 from registro.cambios_estado c
                                                                   where c.dispositivo_id = d.id and c.fuente = 'anubis' and not c.aplicado))
                       order by d.activo desc, d.grupo, d.orden, d.nombre)
        from registro.dispositivos d), '[]'::jsonb),
    'personas', coalesce((
      select jsonb_agg(jsonb_build_object('id', p.id, 'nombre', p.nombre, 'grupo', p.grupo, 'activo', p.activo)
                       order by p.activo desc, case p.grupo when 'Jefe' then 0 when 'Operario' then 1 else 2 end, p.nombre)
        from registro.personas p), '[]'::jsonb),
    'avisos', coalesce((
      select jsonb_agg(jsonb_build_object('id', v.id, 'dispositivo_id', v.dispositivo_id, 'dispositivo', v.dispositivo,
                                          'texto', v.texto, 'por', v.por, 'ts', v.ts)
                       order by v.ts desc)
        from registro.avisos v where not v.resuelto), '[]'::jsonb)
  );
$$;

-- ── Cambiar el estado desde Anubis (pulsación larga): sin PIN, con la razón siempre guardada ─────────────
-- args: dispositivo_id, persona (quién lo hace, de la lista), estado, nota = la razón (obligatoria, mínimo 5, para con fallo,
--       averiado y en reparación; opcional para operativo y baja)
create or replace function registro.a_cambiar_estado(a jsonb) returns jsonb
language plpgsql security definer set search_path = registro, pg_temp as $$
declare
  d        registro.dispositivos%rowtype;
  v_por    text;
  v_est    text := lower(btrim(coalesce(a->>'estado', '')));
  v_nota   text := nullif(left(btrim(coalesce(a->>'nota', '')), 200), '');
begin
  select nombre into v_por from registro.personas
   where activo and lower(btrim(nombre)) = lower(btrim(coalesce(a->>'persona', '')));
  if not found then raise exception 'Elige quién eres (la persona tiene que estar en la lista de Ajustes).'; end if;

  select * into d from registro.dispositivos
   where id = (a->>'dispositivo_id')::uuid and activo for update;
  if not found then raise exception 'No encuentro ese dispositivo.'; end if;

  if not (v_est = any (registro.estados_permitidos(d.grupo, d.origen))) then
    raise exception 'Ese estado no vale para %.', d.nombre;
  end if;
  if v_est in ('fallo', 'averiado', 'reparacion') and (v_nota is null or length(v_nota) < 5) then
    raise exception 'Escribe la razón del estado (mínimo 5 letras).';
  end if;

  -- ya está así: mismo estado y misma razón (a operativo no hay razón que comparar: no hay nada que cambiar)
  if d.estado = v_est and (v_est = 'operativo' or d.estado_nota is not distinct from v_nota) then
    return registro.estado() || jsonb_build_object('ya', true);
  end if;

  perform registro.fijar_estado(d.id, v_est, v_nota, v_por, 'anubis');
  return registro.estado();
end $$;

-- ── Historial (también sirve para exportar: p_max = 5000): movimientos + cambios de estado ───────────────
-- Cada fila lleva los campos de siempre y, en las de cambio de estado (accion = 'estado'), también estado, estado_anterior y fuente
-- ('anubis' | 'centinela'); en esas, `persona` es quien lo marcó y `nota` la razón.
create or replace function registro.a_historial(a jsonb, p_max int) returns jsonb
language plpgsql stable security definer set search_path = registro, pg_temp as $$
declare
  v_lim   int := least(greatest(coalesce((a->>'limite')::int, 50), 1), p_max);
  v_off   int := greatest(coalesce((a->>'desplazamiento')::int, 0), 0);
  v_disp  uuid := nullif(a->>'dispositivo_id', '')::uuid;
  v_pers  text := nullif(btrim(coalesce(a->>'persona', '')), '');
  v_acc   text := nullif(a->>'accion', '');
  v_desde timestamptz;
  v_hasta timestamptz;
  v_filas jsonb;
  v_mas   boolean;
begin
  if v_acc is not null and v_acc not in ('coger', 'dejar', 'estado') then raise exception 'Filtro de acción no válido.'; end if;
  if nullif(a->>'desde', '') is not null then
    v_desde := ((a->>'desde')::date)::timestamp at time zone 'Europe/Madrid';
  end if;
  if nullif(a->>'hasta', '') is not null then
    v_hasta := (((a->>'hasta')::date) + 1)::timestamp at time zone 'Europe/Madrid';
  end if;

  select coalesce(jsonb_agg(to_jsonb(t) order by t.ts desc, t.id desc, t.accion), '[]'::jsonb) into v_filas
    from (select u.id, u.ts, u.dispositivo, u.persona, u.accion, u.nota, u.por, u.automatico, u.desde, u.estado, u.estado_anterior, u.fuente
            from (select m.id, m.ts, m.dispositivo_id, m.dispositivo, m.persona, m.accion, m.nota, m.por, m.automatico, m.desde,
                         null::text as estado, null::text as estado_anterior, null::text as fuente
                    from registro.movimientos m
                  union all
                  select c.id, c.ts, c.dispositivo_id, x.nombre, c.por, 'estado'::text, c.nota, null::text, false, null::timestamptz,
                         c.estado, c.estado_anterior, c.fuente
                    from registro.cambios_estado c
                    join registro.dispositivos x on x.id = c.dispositivo_id) u
           where (v_disp  is null or u.dispositivo_id = v_disp)
             and (v_pers  is null or lower(u.persona) = lower(v_pers))
             and (v_acc   is null or u.accion = v_acc)
             and (v_desde is null or u.ts >= v_desde)
             and (v_hasta is null or u.ts <  v_hasta)
           order by u.ts desc, u.id desc, u.accion
           limit v_lim + 1 offset v_off) t;

  v_mas := jsonb_array_length(v_filas) > v_lim;
  if v_mas then v_filas := v_filas - v_lim; end if;        -- quita la fila de más (índice v_lim)
  return jsonb_build_object('ok', true, 'filas', v_filas, 'mas', v_mas);
end $$;

-- ── Sincronización con Centinela: igual que en 008, salvo que a Centinela solo se le manda la razón si el estado NO es operativo ──
create or replace function registro.a_sync_centinela(a jsonb) returns jsonb
language plpgsql security definer set search_path = registro, pg_temp as $$
declare
  it        jsonb;
  ak        jsonb;
  d         registro.dispositivos%rowtype;
  v_items   jsonb := case when jsonb_typeof(a->'items') = 'array' then a->'items' else '[]'::jsonb end;
  v_acks    jsonb := case when jsonb_typeof(a->'acks') = 'array' then a->'acks' else '[]'::jsonb end;
  v_sim     boolean := coalesce((a->>'simular')::boolean, false);
  v_origen  text; v_oid text; v_serie text; v_est text; v_nota text; v_nombre text; v_grupo text; v_nom_final text; v_n int;
  v_vinc int := 0; v_crea int := 0; v_estd int := 0; v_sin int := 0; v_esp int := 0; v_ign int := 0;
  v_pend    jsonb;
  v_crear_d boolean := coalesce((a->'crear'->>'dispositivos')::boolean, false);
  v_crear_m boolean := coalesce((a->'crear'->>'maquinaria')::boolean, true);
  v_sinv    jsonb := '[]'::jsonb; v_sinv_n int := 0;
begin
  if jsonb_array_length(v_items) > 500 or jsonb_array_length(v_acks) > 500 then raise exception 'Demasiados datos de golpe.'; end if;

  begin
    -- 1) lo que Centinela ya ha reflejado
    for ak in select * from jsonb_array_elements(v_acks) loop
      if jsonb_typeof(ak->'id') = 'number' then
        update registro.cambios_estado
           set aplicado = true, aplicado_ts = clock_timestamp(),
               resultado = case when coalesce((ak->>'ok')::boolean, true) then null else left('ERROR: ' || coalesce(ak->>'error', ''), 200) end
         where id = (ak->>'id')::bigint and fuente = 'anubis' and not aplicado;
      end if;
    end loop;

    -- 2) altas y estados que manda Centinela
    for it in select * from jsonb_array_elements(v_items) loop
      v_origen := it->>'origen';
      v_oid    := nullif(left(btrim(coalesce(it->>'origen_id', '')), 40), '');
      v_est    := lower(btrim(coalesce(it->>'estado', '')));
      v_nota   := nullif(left(btrim(coalesce(it->>'nota', '')), 200), '');
      v_serie  := nullif(left(btrim(coalesce(it->>'serie', '')), 80), '');
      v_nombre := nullif(left(btrim(coalesce(it->>'nombre', '')), 80), '');
      if v_origen not in ('dispositivos', 'maquinaria') or v_oid is null
         or v_est not in ('operativo', 'fallo', 'averiado', 'reparacion', 'baja') then
        v_ign := v_ign + 1; continue;
      end if;
      if not (v_est = any (registro.estados_permitidos(case when v_origen = 'maquinaria' then 'Máquina' else 'Otro' end, v_origen))) then
        v_ign := v_ign + 1; continue;
      end if;

      d := null;
      select * into d from registro.dispositivos where origen = v_origen and origen_id = v_oid for update;
      if not found and v_serie is not null then
        -- primera vez: se vincula con el dispositivo de Anubis que tiene ese mismo número de serie y aún no está vinculado
        select * into d from registro.dispositivos
         where origen is null and serie is not null and lower(btrim(serie)) = lower(v_serie)
           and (v_origen = 'maquinaria') = (grupo = 'Máquina')
         order by activo desc, creado limit 1 for update;
        if found then
          update registro.dispositivos set origen = v_origen, origen_id = v_oid where id = d.id;
          d.origen := v_origen; d.origen_id := v_oid;
          v_vinc := v_vinc + 1;
        end if;
      end if;
      if d.id is null and v_origen = 'maquinaria' then
        -- las máquinas de Anubis se copiaron de Centinela con su número («#9 Torito…» = máquina 9): si la serie no coincide, vale el número
        select * into d from registro.dispositivos
         where origen is null and grupo = 'Máquina' and nombre ~ ('^#\s*' || v_oid || '(\s|$)')
         order by activo desc, creado limit 1 for update;
        if found then
          update registro.dispositivos set origen = v_origen, origen_id = v_oid where id = d.id;
          d.origen := v_origen; d.origen_id := v_oid;
          v_vinc := v_vinc + 1;
        end if;
      end if;

      if d.id is null then
        -- alta nueva desde Centinela (lo dado de baja no se da de alta)
        if v_est = 'baja' then v_ign := v_ign + 1; continue; end if;
        if (v_origen = 'maquinaria' and not v_crear_m) or (v_origen = 'dispositivos' and not v_crear_d) then
          v_sinv_n := v_sinv_n + 1;
          if jsonb_array_length(v_sinv) < 30 then
            v_sinv := v_sinv || jsonb_build_array(jsonb_build_object('origen', v_origen, 'origen_id', v_oid, 'nombre', v_nombre, 'serie', v_serie));
          end if;
          continue;
        end if;
        v_grupo := case when v_origen = 'maquinaria' then 'Máquina'
                        when it->>'grupo' in ('Móvil / lector', 'Ordenador', 'Impresora', 'Otro') then it->>'grupo' else 'Otro' end;
        v_nom_final := coalesce(v_nombre, '#' || v_oid);
        v_n := 1;
        while exists (select 1 from registro.dispositivos where lower(btrim(nombre)) = lower(btrim(v_nom_final))) loop
          v_n := v_n + 1;
          v_nom_final := left(coalesce(v_nombre, '#' || v_oid), 74) || ' (' || v_n || ')';
        end loop;
        insert into registro.dispositivos (nombre, grupo, serie, origen, origen_id)
        values (v_nom_final, v_grupo, v_serie, v_origen, v_oid) returning * into d;
        v_crea := v_crea + 1;
        if v_est <> 'operativo' then
          perform registro.fijar_estado(d.id, v_est, v_nota, 'Centinela', 'centinela');
          v_estd := v_estd + 1;
        end if;
        continue;
      end if;

      -- ya existe: la serie la manda Centinela; el estado también, salvo que un cambio hecho en Anubis esté esperando
      if v_serie is not null and d.serie is distinct from v_serie then
        update registro.dispositivos set serie = v_serie where id = d.id;
      end if;
      if exists (select 1 from registro.cambios_estado c where c.dispositivo_id = d.id and c.fuente = 'anubis' and not c.aplicado) then
        v_esp := v_esp + 1; continue;
      end if;
      if v_est = 'operativo' then v_nota := null; end if;
      if d.estado = v_est and d.estado_nota is not distinct from v_nota then
        v_sin := v_sin + 1;
      else
        perform registro.fijar_estado(d.id, v_est, v_nota, 'Centinela', 'centinela');
        v_estd := v_estd + 1;
      end if;
    end loop;

    -- 3) lo que se ha cambiado en Anubis y Centinela todavía tiene que reflejar (en orden)
    select coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'origen', c.origen, 'origen_id', c.origen_id, 'estado', c.estado,
                                                  'nota', case when c.estado = 'operativo' then null else c.nota end, 'por', c.por, 'ts', c.ts, 'dispositivo', x.nombre) order by c.id), '[]'::jsonb)
      into v_pend
      from (select * from registro.cambios_estado where fuente = 'anubis' and not aplicado and origen is not null order by id limit 100) c
      join registro.dispositivos x on x.id = c.dispositivo_id;

    if v_sim then raise exception 'simulado'; end if;
  exception when raise_exception then
    if sqlerrm <> 'simulado' then raise; end if;
  end;

  return jsonb_build_object('ok', true, 'simulado', v_sim,
    'resumen', jsonb_build_object('vinculados', v_vinc, 'creados', v_crea, 'estados', v_estd, 'sin_cambio', v_sin, 'esperando', v_esp, 'ignorados', v_ign,
                                  'sin_vincular', v_sinv_n),
    'sin_vincular', v_sinv,
    'pendientes', coalesce(v_pend, '[]'::jsonb));
end $$;

-- ── Puerta única: igual que en 008, pero `cambiar_estado` y `fuera_servicio` ya no piden el PIN ───────────
create or replace function public.rd_accion(p_clave text, p_accion text, p_args jsonb default '{}'::jsonb)
returns jsonb
language plpgsql security definer set search_path = registro, extensions, public, pg_temp as $$
declare v_cod text; v_args jsonb := coalesce(p_args, '{}'::jsonb); v_res jsonb;
begin
  v_cod := registro.comprobar_clave(p_clave);
  if v_cod is not null then
    return jsonb_build_object('ok', false, 'codigo', v_cod, 'error',
      case v_cod when 'bloqueado' then 'Demasiados intentos. Espera unos minutos.'
                 when 'sin_clave' then 'Todavía no hay clave configurada.'
                 else 'Clave no válida.' end);
  end if;

  if p_accion = any (array['comprobar_pin', 'historial', 'exportar', 'avisos', 'resolver_aviso',
                           'estadisticas', 'sync_centinela',
                           'guardar_dispositivo', 'archivar_dispositivo', 'importar_dispositivos',
                           'guardar_persona', 'archivar_persona', 'importar_personas',
                           'cambiar_clave', 'cambiar_pin']) then
    v_cod := registro.comprobar_pin(case when jsonb_typeof(v_args->'pin') = 'string' then v_args->>'pin' end);
    if v_cod is not null then
      return jsonb_build_object('ok', false, 'codigo', 'pin', 'bloqueado', v_cod = 'bloqueado_pin', 'error',
        case v_cod when 'bloqueado_pin' then 'Demasiados intentos con el PIN. Espera 10 minutos.'
                   else 'PIN no válido.' end);
    end if;
  end if;

  begin
    v_res := case p_accion
      when 'comprobar'             then jsonb_build_object('ok', true)
      when 'comprobar_pin'         then jsonb_build_object('ok', true)
      when 'estado'                then registro.estado()
      when 'coger'                 then registro.a_coger(v_args)
      when 'dejar'                 then registro.a_dejar(v_args)
      when 'pasar'                 then registro.a_pasar(v_args)
      when 'avisar'                then registro.a_avisar(v_args)
      when 'avisos'                then registro.a_avisos(v_args)
      when 'resolver_aviso'        then registro.a_resolver_aviso(v_args)
      when 'fuera_servicio'        then registro.a_fuera_servicio(v_args)
      when 'cambiar_estado'        then registro.a_cambiar_estado(v_args)
      when 'sync_centinela'        then registro.a_sync_centinela(v_args)
      when 'estadisticas'          then registro.a_estadisticas(v_args)
      when 'historial'             then registro.a_historial(v_args, 200)
      when 'exportar'              then registro.a_historial(v_args, 5000)
      when 'guardar_dispositivo'   then registro.a_guardar_dispositivo(v_args)
      when 'archivar_dispositivo'  then registro.a_archivar_dispositivo(v_args)
      when 'importar_dispositivos' then registro.a_importar_dispositivos(v_args)
      when 'guardar_persona'       then registro.a_guardar_persona(v_args)
      when 'archivar_persona'      then registro.a_archivar_persona(v_args)
      when 'importar_personas'     then registro.a_importar_personas(v_args)
      when 'cambiar_clave'         then registro.a_cambiar_clave(v_args)
      when 'cambiar_pin'           then registro.a_cambiar_pin(v_args)
      else null end;
    if v_res is null then
      return jsonb_build_object('ok', false, 'codigo', 'accion', 'error', 'Acción desconocida.');
    end if;
    return v_res;
  exception
    when raise_exception then
      return jsonb_build_object('ok', false, 'codigo', 'error', 'error', sqlerrm);
    when invalid_text_representation or invalid_datetime_format or datetime_field_overflow or numeric_value_out_of_range then
      return jsonb_build_object('ok', false, 'codigo', 'error', 'error', 'Datos no válidos.');
    when others then
      return jsonb_build_object('ok', false, 'codigo', 'error', 'error', 'Error inesperado.');
  end;
end $$;

-- ── Permisos: nada público ──────────────────────────────────────────────────
revoke all on schema registro from public, anon, authenticated;
revoke all on all tables    in schema registro from public, anon, authenticated;
revoke all on all functions in schema registro from public, anon, authenticated;
revoke execute on function public.rd_accion(text, text, jsonb) from public, anon, authenticated;
grant  execute on function public.rd_accion(text, text, jsonb) to service_role;
