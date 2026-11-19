-- ============================================================================
-- Registro de dispositivos · 003: PIN de 4 dígitos para Historial/Ajustes y avisos de avería.
--
-- · PIN: protege (en el servidor, no solo en pantalla) el historial, la exportación, los ajustes,
--   los avisos de los jefes y el cambio de clave. Se guarda con hash (bcrypt) y tiene su propio
--   límite de intentos: 10 fallos en 10 minutos. Mientras no haya PIN puesto, no se exige.
--   Esta migración NO lleva ningún PIN: se pone aparte (update registro.config set pin_hash = …)
--   o desde la propia web (Ajustes → Otros → «Poner un PIN»).
-- · Avisos: cualquiera puede avisar de un problema de un dispositivo; sale en su cuadro y al
--   cogerlo; los jefes (con el PIN) los ven en la pestaña Avisos y los marcan como resueltos.
--
-- Requiere 001. Se puede volver a ejecutar sin romper nada. Para deshacer: 002_deshacer.sql borra todo.
-- ============================================================================

alter table registro.config add column if not exists pin_hash text;

create table if not exists registro.fallos_pin (
  ts timestamptz not null default now()
);
create index if not exists fallos_pin_ts on registro.fallos_pin (ts);

create table if not exists registro.avisos (
  id             bigint generated always as identity primary key,
  ts             timestamptz not null default now(),
  dispositivo_id uuid not null references registro.dispositivos (id),
  dispositivo    text not null,
  texto          text not null check (length(btrim(texto)) between 1 and 300),
  por            text not null,
  resuelto       boolean not null default false,
  resuelto_por   text,
  resuelto_ts    timestamptz,
  resuelto_nota  text
);
create index if not exists avisos_abiertos on registro.avisos (dispositivo_id) where not resuelto;
create index if not exists avisos_ts       on registro.avisos (ts desc);

alter table registro.fallos_pin enable row level security;
alter table registro.avisos     enable row level security;

-- ── PIN ─────────────────────────────────────────────────────────────────────
-- null = PIN correcto (o no hay PIN puesto); si no, 'pin' o 'bloqueado_pin'
create or replace function registro.comprobar_pin(p_pin text) returns text
language plpgsql security definer set search_path = registro, extensions, pg_temp as $$
declare v_hash text; v_fallos int;
begin
  select pin_hash into v_hash from registro.config where id = 1;
  if v_hash is null then return null; end if;
  select count(*) into v_fallos from registro.fallos_pin where ts > now() - interval '10 minutes';
  if v_fallos >= 10 then return 'bloqueado_pin'; end if;
  if p_pin is null or p_pin !~ '^[0-9]{4}$' or crypt(p_pin, v_hash) <> v_hash then
    insert into registro.fallos_pin default values;
    delete from registro.fallos_pin where ts < now() - interval '1 day';
    return 'pin';
  end if;
  return null;
end $$;

create or replace function registro.a_cambiar_pin(a jsonb) returns jsonb
language plpgsql security definer set search_path = registro, extensions, pg_temp as $$
declare v_nuevo text := coalesce(a->>'nueva', '');
begin
  if v_nuevo !~ '^[0-9]{4}$' then raise exception 'El PIN tiene que ser de 4 números.'; end if;
  update registro.config set pin_hash = crypt(v_nuevo, gen_salt('bf', 10)), actualizada = now() where id = 1;
  delete from registro.fallos_pin;
  return registro.estado();
end $$;

-- ── Estado (ahora con avisos abiertos y si hay PIN) ─────────────────────────
create or replace function registro.estado() returns jsonb
language sql stable security definer set search_path = registro, pg_temp as $$
  select jsonb_build_object(
    'ok', true,
    'ahora', now(),
    'con_pin', coalesce((select pin_hash is not null from registro.config where id = 1), false),
    'dispositivos', coalesce((
      select jsonb_agg(jsonb_build_object('id', d.id, 'nombre', d.nombre, 'grupo', d.grupo, 'serie', d.serie,
                                          'activo', d.activo, 'tiene', d.tiene, 'desde', d.desde)
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

-- ── Avisos ──────────────────────────────────────────────────────────────────
create or replace function registro.a_avisar(a jsonb) returns jsonb
language plpgsql security definer set search_path = registro, pg_temp as $$
declare
  d      registro.dispositivos%rowtype;
  v_por  text;
  v_txt  text := left(btrim(coalesce(a->>'texto', '')), 300);
begin
  select nombre into v_por from registro.personas
   where activo and lower(btrim(nombre)) = lower(btrim(coalesce(a->>'persona', '')));
  if not found then raise exception 'Elige quién eres (la persona tiene que estar en la lista de Ajustes).'; end if;
  if v_txt = '' then raise exception 'Escribe qué le pasa.'; end if;
  select * into d from registro.dispositivos where id = (a->>'dispositivo_id')::uuid and activo;
  if not found then raise exception 'No encuentro ese dispositivo.'; end if;
  if (select count(*) from registro.avisos where dispositivo_id = d.id and not resuelto) >= 5 then
    raise exception 'Ya hay 5 avisos abiertos de este dispositivo. Que los jefes los revisen.';
  end if;
  insert into registro.avisos (dispositivo_id, dispositivo, texto, por) values (d.id, d.nombre, v_txt, v_por);
  return registro.estado();
end $$;

create or replace function registro.a_resolver_aviso(a jsonb) returns jsonb
language plpgsql security definer set search_path = registro, pg_temp as $$
declare
  v_por  text;
  v_nota text := nullif(left(btrim(coalesce(a->>'nota', '')), 200), '');
begin
  select nombre into v_por from registro.personas
   where activo and lower(btrim(nombre)) = lower(btrim(coalesce(a->>'persona', '')));
  if not found then raise exception 'Elige quién eres (la persona tiene que estar en la lista de Ajustes).'; end if;
  update registro.avisos
     set resuelto = true, resuelto_por = v_por, resuelto_ts = clock_timestamp(), resuelto_nota = v_nota
   where id = (a->>'id')::bigint and not resuelto;
  if not found then raise exception 'Ese aviso ya estaba resuelto o no existe.'; end if;
  return registro.estado();
end $$;

-- abiertos primero y luego los resueltos, los últimos 100 en total
create or replace function registro.a_avisos(a jsonb) returns jsonb
language sql stable security definer set search_path = registro, pg_temp as $$
  select jsonb_build_object('ok', true, 'avisos', coalesce((
    select jsonb_agg(to_jsonb(t) order by t.resuelto, t.ts desc)
      from (select id, ts, dispositivo, texto, por, resuelto, resuelto_por, resuelto_ts, resuelto_nota
              from registro.avisos order by resuelto, ts desc limit 100) t), '[]'::jsonb));
$$;

-- ── La única puerta (con la comprobación del PIN) ───────────────────────────
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
      when 'avisar'                then registro.a_avisar(v_args)
      when 'avisos'                then registro.a_avisos(v_args)
      when 'resolver_aviso'        then registro.a_resolver_aviso(v_args)
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
