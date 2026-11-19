-- ============================================================================
-- Registro de dispositivos · 007: fuera de servicio, traspaso directo, estadísticas y sincronización sin conexión.
--
-- · Fuera de servicio: un jefe (con el PIN) marca una máquina o dispositivo como «fuera de servicio» con un motivo;
--   nadie puede cogerlo ni pasárselo hasta que un jefe lo vuelva a poner en servicio. Queda registro en fuera_log.
-- · Traspaso directo (pasar): quien lo tiene se lo pasa a otra persona en un solo paso (se anota que el primero lo deja
--   y que el segundo lo recibe, con la misma hora).
-- · Estadísticas (solo con el PIN): usos, horas, olvidos de más de 8 h, lo que más y menos se usa y las horas punta.
-- · Sin conexión: coger, dejar, pasar y avisar aceptan «cuando» (la hora en que se hizo en el móvil, hasta 2 días antes,
--   nunca en el futuro y nunca antes del último movimiento de ese dispositivo). Un aviso repetido (mismo texto, mismo autor,
--   mismo dispositivo, 10 minutos) no se duplica: así reenviar una cola no crea avisos de más.
--
-- Requiere 001 y 003. Se puede volver a ejecutar sin romper nada. Para deshacer: 007_deshacer.sql.
-- ============================================================================

alter table registro.dispositivos
  add column if not exists fuera        boolean not null default false,
  add column if not exists fuera_motivo text,
  add column if not exists fuera_desde  timestamptz,
  add column if not exists fuera_por    text;

create table if not exists registro.fuera_log (
  id             bigint generated always as identity primary key,
  ts             timestamptz not null default now(),
  dispositivo_id uuid not null references registro.dispositivos (id),
  dispositivo    text not null,
  accion         text not null check (accion in ('fuera', 'servicio')),
  motivo         text,
  por            text not null
);
create index if not exists fuera_log_ts on registro.fuera_log (ts desc);
alter table registro.fuera_log enable row level security;

-- ── Hora de un movimiento hecho sin conexión ────────────────────────────────
-- «cuando» (ISO) solo vale si es de los últimos 2 días y no está en el futuro; si no, se usa la hora del servidor.
create or replace function registro.cuando_valido(a jsonb) returns timestamptz
language plpgsql stable set search_path = registro, pg_temp as $$
declare v timestamptz;
begin
  if jsonb_typeof(a->'cuando') is distinct from 'string' then return null; end if;
  v := (a->>'cuando')::timestamptz;
  if v > clock_timestamp() + interval '2 minutes' or v < clock_timestamp() - interval '2 days' then return null; end if;
  return least(v, clock_timestamp());
exception when others then
  return null;
end $$;

-- hora del movimiento: la de «cuando» si es válida, y nunca anterior al último movimiento de ese dispositivo
create or replace function registro.ts_movimiento(a jsonb, p_disp uuid) returns timestamptz
language sql stable set search_path = registro, pg_temp as $$
  select greatest(coalesce(registro.cuando_valido(a), clock_timestamp()),
                  coalesce((select max(m.ts) from registro.movimientos m where m.dispositivo_id = p_disp), '-infinity'::timestamptz));
$$;

-- ── Estado: ahora cada dispositivo dice si está fuera de servicio ───────────
create or replace function registro.estado() returns jsonb
language sql stable security definer set search_path = registro, pg_temp as $$
  select jsonb_build_object(
    'ok', true,
    'ahora', now(),
    'con_pin', coalesce((select pin_hash is not null from registro.config where id = 1), false),
    'dispositivos', coalesce((
      select jsonb_agg(jsonb_build_object('id', d.id, 'nombre', d.nombre, 'grupo', d.grupo, 'serie', d.serie,
                                          'activo', d.activo, 'tiene', d.tiene, 'desde', d.desde,
                                          'fuera', d.fuera, 'fuera_motivo', d.fuera_motivo, 'fuera_desde', d.fuera_desde)
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

-- ── Coger (no se puede si está fuera de servicio) ───────────────────────────
create or replace function registro.a_coger(a jsonb) returns jsonb
language plpgsql security definer set search_path = registro, pg_temp as $$
declare
  d        registro.dispositivos%rowtype;
  v_pers   text;
  v_nota   text := nullif(left(btrim(coalesce(a->>'nota', '')), 200), '');
  v_forzar boolean := coalesce((a->>'forzar')::boolean, false);
  v_esp    text := nullif(btrim(coalesce(a->>'tiene', '')), '');     -- quién lo tenía cuando se pidió (opcional, con «forzar»)
  v_ahora  timestamptz;
begin
  select nombre into v_pers from registro.personas
   where activo and lower(btrim(nombre)) = lower(btrim(coalesce(a->>'persona', '')));
  if not found then raise exception 'Elige quién eres (la persona tiene que estar en la lista de Ajustes).'; end if;

  select * into d from registro.dispositivos
   where id = (a->>'dispositivo_id')::uuid and activo for update;
  if not found then raise exception 'No encuentro ese dispositivo.'; end if;

  if d.tiene is not null and lower(d.tiene) = lower(v_pers) then
    return registro.estado() || jsonb_build_object('ya', true);       -- ya lo tenía esa persona
  end if;

  if d.fuera then
    return registro.estado() || jsonb_build_object('ok', false, 'codigo', 'fuera',
             'error', 'Está fuera de servicio: ' || coalesce(d.fuera_motivo, 'sin motivo') || '.');
  end if;

  v_ahora := registro.ts_movimiento(a, d.id);

  if d.tiene is not null then
    if not v_forzar then
      return registro.estado() || jsonb_build_object('ok', false, 'codigo', 'ocupado',
               'error', 'Ya lo tiene ' || d.tiene || '.', 'tiene', d.tiene, 'desde', d.desde);
    end if;
    -- cogerlo «forzando» solo vale si sigue en manos de quien se veía en pantalla (o en una cola reenviada)
    if v_esp is not null and lower(d.tiene) <> lower(v_esp) then
      return registro.estado() || jsonb_build_object('ok', false, 'codigo', 'cambio',
               'error', 'Ahora lo tiene ' || d.tiene || ', no ' || v_esp || ': la pantalla estaba desfasada.', 'tiene', d.tiene);
    end if;
    insert into registro.movimientos (ts, dispositivo_id, dispositivo, persona, accion, nota, por, automatico, desde)
    values (v_ahora, d.id, d.nombre, d.tiene, 'dejar', 'Pasa a ' || v_pers, v_pers, true, d.desde);
  end if;

  insert into registro.movimientos (ts, dispositivo_id, dispositivo, persona, accion, nota)
  values (v_ahora, d.id, d.nombre, v_pers, 'coger', v_nota);
  update registro.dispositivos set tiene = v_pers, desde = v_ahora where id = d.id;
  return registro.estado();
end $$;

create or replace function registro.a_dejar(a jsonb) returns jsonb
language plpgsql security definer set search_path = registro, pg_temp as $$
declare
  d       registro.dispositivos%rowtype;
  v_por   text;
  v_nota  text := nullif(left(btrim(coalesce(a->>'nota', '')), 200), '');
  v_esp   text := nullif(btrim(coalesce(a->>'tiene', '')), '');      -- quién lo tenía cuando se pidió (opcional)
  v_ahora timestamptz;
begin
  select nombre into v_por from registro.personas
   where activo and lower(btrim(nombre)) = lower(btrim(coalesce(a->>'persona', '')));
  if not found then raise exception 'Elige quién eres (la persona tiene que estar en la lista de Ajustes).'; end if;

  select * into d from registro.dispositivos
   where id = (a->>'dispositivo_id')::uuid and activo for update;
  if not found then raise exception 'No encuentro ese dispositivo.'; end if;

  if d.tiene is null then
    return registro.estado() || jsonb_build_object('ya', true);       -- ya estaba libre
  end if;
  -- si ya lo tiene otra persona distinta de la que se veía en pantalla (o en una cola reenviada), no se le quita
  if v_esp is not null and lower(d.tiene) <> lower(v_esp) then
    return registro.estado() || jsonb_build_object('ok', false, 'codigo', 'cambio',
             'error', 'Ahora lo tiene ' || d.tiene || ': la pantalla estaba desfasada.', 'tiene', d.tiene);
  end if;

  v_ahora := registro.ts_movimiento(a, d.id);
  insert into registro.movimientos (ts, dispositivo_id, dispositivo, persona, accion, nota, por, desde)
  values (v_ahora, d.id, d.nombre, d.tiene, 'dejar', v_nota,
          case when lower(v_por) = lower(d.tiene) then null else v_por end, d.desde);
  update registro.dispositivos set tiene = null, desde = null where id = d.id;
  return registro.estado();
end $$;

-- ── Pasar: de quien lo tiene a otra persona, en un solo paso ────────────────
-- args: dispositivo_id, persona (quién lo registra), para (quién lo recibe), nota (opcional), cuando (opcional)
create or replace function registro.a_pasar(a jsonb) returns jsonb
language plpgsql security definer set search_path = registro, pg_temp as $$
declare
  d       registro.dispositivos%rowtype;
  v_por   text;
  v_para  text;
  v_nota  text := nullif(left(btrim(coalesce(a->>'nota', '')), 200), '');
  v_de    text := nullif(btrim(coalesce(a->>'de', '')), '');          -- quién lo tenía cuando se pidió (opcional)
  v_ahora timestamptz;
begin
  select nombre into v_por from registro.personas
   where activo and lower(btrim(nombre)) = lower(btrim(coalesce(a->>'persona', '')));
  if not found then raise exception 'Elige quién eres (la persona tiene que estar en la lista de Ajustes).'; end if;
  select nombre into v_para from registro.personas
   where activo and lower(btrim(nombre)) = lower(btrim(coalesce(a->>'para', '')));
  if not found then raise exception 'Elige a quién se lo pasas (la persona tiene que estar en la lista de Ajustes).'; end if;

  select * into d from registro.dispositivos
   where id = (a->>'dispositivo_id')::uuid and activo for update;
  if not found then raise exception 'No encuentro ese dispositivo.'; end if;

  if d.tiene is null then raise exception 'Ahora no lo tiene nadie: cógelo en vez de pasarlo.'; end if;
  if lower(d.tiene) = lower(v_para) then
    return registro.estado() || jsonb_build_object('ya', true);       -- ya lo tiene esa persona (p. ej. reenvío de una cola)
  end if;
  if v_de is not null and lower(d.tiene) <> lower(v_de) then
    return registro.estado() || jsonb_build_object('ok', false, 'codigo', 'cambio',
             'error', 'Ahora lo tiene ' || d.tiene || ', no ' || v_de || ': la pantalla estaba desfasada.', 'tiene', d.tiene);
  end if;
  if d.fuera then
    return registro.estado() || jsonb_build_object('ok', false, 'codigo', 'fuera',
             'error', 'Está fuera de servicio: ' || coalesce(d.fuera_motivo, 'sin motivo') || '.');
  end if;

  v_ahora := registro.ts_movimiento(a, d.id);
  insert into registro.movimientos (ts, dispositivo_id, dispositivo, persona, accion, nota, por, automatico, desde)
  values (v_ahora, d.id, d.nombre, d.tiene, 'dejar', 'Pasa a ' || v_para,
          case when lower(v_por) = lower(d.tiene) then null else v_por end, true, d.desde);
  insert into registro.movimientos (ts, dispositivo_id, dispositivo, persona, accion, nota, por)
  values (v_ahora, d.id, d.nombre, v_para, 'coger', coalesce(v_nota, 'Recibe de ' || d.tiene),
          case when lower(v_por) = lower(v_para) then null else v_por end);
  update registro.dispositivos set tiene = v_para, desde = v_ahora where id = d.id;
  return registro.estado();
end $$;

-- ── Fuera de servicio / volver a ponerlo en servicio (zona de jefes: lleva PIN) ─
-- args: dispositivo_id, persona (quién lo hace), fuera (true/false), motivo (obligatorio al ponerlo fuera; al volver, opcional)
create or replace function registro.a_fuera_servicio(a jsonb) returns jsonb
language plpgsql security definer set search_path = registro, pg_temp as $$
declare
  d        registro.dispositivos%rowtype;
  v_por    text;
  v_fuera  boolean := coalesce((a->>'fuera')::boolean, true);
  v_motivo text := nullif(left(btrim(coalesce(a->>'motivo', '')), 200), '');
begin
  select nombre into v_por from registro.personas
   where activo and lower(btrim(nombre)) = lower(btrim(coalesce(a->>'persona', '')));
  if not found then raise exception 'Elige quién eres (la persona tiene que estar en la lista de Ajustes).'; end if;

  select * into d from registro.dispositivos
   where id = (a->>'dispositivo_id')::uuid and activo for update;
  if not found then raise exception 'No encuentro ese dispositivo.'; end if;

  if v_fuera then
    if v_motivo is null or length(v_motivo) < 3 then raise exception 'Escribe el motivo (qué le pasa).'; end if;
    if d.fuera then return registro.estado() || jsonb_build_object('ya', true); end if;
    update registro.dispositivos
       set fuera = true, fuera_motivo = v_motivo, fuera_desde = clock_timestamp(), fuera_por = v_por
     where id = d.id;
    insert into registro.fuera_log (dispositivo_id, dispositivo, accion, motivo, por) values (d.id, d.nombre, 'fuera', v_motivo, v_por);
  else
    if not d.fuera then return registro.estado() || jsonb_build_object('ya', true); end if;
    update registro.dispositivos
       set fuera = false, fuera_motivo = null, fuera_desde = null, fuera_por = null
     where id = d.id;
    insert into registro.fuera_log (dispositivo_id, dispositivo, accion, motivo, por) values (d.id, d.nombre, 'servicio', v_motivo, v_por);
  end if;
  return registro.estado();
end $$;

-- ── Avisos: sin duplicar un reenvío y con la hora real si se hizo sin conexión ─
create or replace function registro.a_avisar(a jsonb) returns jsonb
language plpgsql security definer set search_path = registro, pg_temp as $$
declare
  d      registro.dispositivos%rowtype;
  v_por  text;
  v_txt  text := left(btrim(coalesce(a->>'texto', '')), 300);
  v_ts   timestamptz := coalesce(registro.cuando_valido(a), clock_timestamp());
begin
  select nombre into v_por from registro.personas
   where activo and lower(btrim(nombre)) = lower(btrim(coalesce(a->>'persona', '')));
  if not found then raise exception 'Elige quién eres (la persona tiene que estar en la lista de Ajustes).'; end if;
  if v_txt = '' then raise exception 'Escribe qué le pasa.'; end if;
  select * into d from registro.dispositivos where id = (a->>'dispositivo_id')::uuid and activo;
  if not found then raise exception 'No encuentro ese dispositivo.'; end if;
  if exists (select 1 from registro.avisos
              where dispositivo_id = d.id and not resuelto and por = v_por and texto = v_txt
                and ts >= v_ts - interval '10 minutes') then
    return registro.estado() || jsonb_build_object('ya', true);
  end if;
  if (select count(*) from registro.avisos where dispositivo_id = d.id and not resuelto) >= 5 then
    raise exception 'Ya hay 5 avisos abiertos de este dispositivo. Que los jefes los revisen.';
  end if;
  insert into registro.avisos (ts, dispositivo_id, dispositivo, texto, por) values (v_ts, d.id, d.nombre, v_txt, v_por);
  return registro.estado();
end $$;

-- ── Estadísticas (zona de jefes: lleva PIN) ─────────────────────────────────
-- args: dias (1 a 365; por defecto 30). Cuenta los «dejar» del periodo: cada uno es un uso cerrado
-- (de «desde» hasta «ts»). Un uso de 8 horas o más cuenta como olvido.
create or replace function registro.a_estadisticas(a jsonb) returns jsonb
language plpgsql stable security definer set search_path = registro, pg_temp as $$
declare
  v_dias  int := least(greatest(coalesce((a->>'dias')::int, 30), 1), 365);
  v_desde timestamptz;
  v_res   jsonb;
begin
  v_desde := (date_trunc('day', now() at time zone 'Europe/Madrid') - make_interval(days => v_dias - 1)) at time zone 'Europe/Madrid';
  with usos as (
    select m.persona, m.dispositivo_id, m.dispositivo, m.ts, m.desde, m.automatico, m.nota,
           greatest(round(extract(epoch from (m.ts - m.desde)) / 60)::int, 0) as minutos
      from registro.movimientos m
     where m.accion = 'dejar' and m.desde is not null and m.ts >= v_desde
  ), por_persona as (
    select persona, count(*)::int as usos, sum(minutos)::int as minutos, (count(*) filter (where minutos >= 480))::int as olvidos
      from usos group by persona order by count(*) desc, sum(minutos) desc, persona limit 15
  ), por_disp as (
    select d.id, d.nombre, d.grupo,
           coalesce(u.usos, 0) as usos, coalesce(u.minutos, 0) as minutos, coalesce(u.olvidos, 0) as olvidos,
           (select max(m.ts) from registro.movimientos m where m.dispositivo_id = d.id and m.accion = 'coger') as ultimo
      from registro.dispositivos d
      left join (select dispositivo_id, count(*)::int as usos, sum(minutos)::int as minutos,
                        (count(*) filter (where minutos >= 480))::int as olvidos
                   from usos group by dispositivo_id) u on u.dispositivo_id = d.id
     where d.activo
  ), horas as (
    select extract(hour from (m.ts at time zone 'Europe/Madrid'))::int as h, count(*)::int as n
      from registro.movimientos m where m.accion = 'coger' and m.ts >= v_desde group by 1
  )
  select jsonb_build_object(
    'ok', true, 'dias', v_dias, 'desde', v_desde,
    'resumen', jsonb_build_object(
      'usos', (select count(*) from usos),
      'minutos', coalesce((select sum(minutos) from usos), 0),
      'media_min', coalesce((select round(avg(minutos))::int from usos), 0),
      'olvidos', (select count(*) from usos where minutos >= 480),
      'traspasos', (select count(*) from usos where automatico and nota like 'Pasa a %'),
      'en_uso_ahora', (select count(*) from registro.dispositivos where activo and tiene is not null),
      'fuera_ahora', (select count(*) from registro.dispositivos where activo and fuera),
      'paradas', (select count(*) from registro.fuera_log where accion = 'fuera' and ts >= v_desde)
    ),
    'personas', coalesce((select jsonb_agg(to_jsonb(p) order by p.usos desc, p.minutos desc, p.persona) from por_persona p), '[]'::jsonb),
    'dispositivos', coalesce((select jsonb_agg(jsonb_build_object(
        'id', p.id, 'nombre', p.nombre, 'grupo', p.grupo, 'usos', p.usos, 'minutos', p.minutos, 'olvidos', p.olvidos,
        'ultimo', p.ultimo,
        'dias_sin_uso', case when p.ultimo is null then null else floor(extract(epoch from (now() - p.ultimo)) / 86400)::int end)
        order by p.usos desc, p.minutos desc, p.nombre) from por_disp p), '[]'::jsonb),
    'olvidos', coalesce((select jsonb_agg(jsonb_build_object(
        'dispositivo', o.dispositivo, 'persona', o.persona, 'desde', o.desde, 'ts', o.ts, 'minutos', o.minutos)
        order by o.ts desc)
      from (select * from usos where minutos >= 480 order by ts desc limit 15) o), '[]'::jsonb),
    'por_hora', (select jsonb_agg(coalesce((select n from horas where horas.h = g), 0) order by g) from generate_series(0, 23) g)
  ) into v_res;
  return v_res;
end $$;

-- ── La única puerta (con las acciones nuevas) ───────────────────────────────
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
                           'fuera_servicio', 'estadisticas',
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
