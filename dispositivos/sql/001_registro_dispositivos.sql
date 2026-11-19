-- ============================================================================
-- Registro de dispositivos: quién coge cada dispositivo o máquina y cuándo lo deja.
--
-- Todo vive en un esquema propio («registro») SIN permisos para anon ni authenticated.
-- La única puerta es public.rd_accion(clave, accion, args): comprueba la clave y hace
-- la acción. Solo la puede ejecutar service_role (la llama la función de borde
-- «dispositivos», ver ../supabase/dispositivos.ts). La clave se guarda con hash (bcrypt).
--
-- Esta migración NO lleva datos ni clave. Los datos iniciales y la clave se cargan aparte.
-- Se puede volver a ejecutar sin romper nada (create if not exists / create or replace).
-- Para deshacerla: 002_deshacer.sql.
-- ============================================================================

create extension if not exists pgcrypto with schema extensions;
create schema if not exists registro;

-- ── Tablas ──────────────────────────────────────────────────────────────────
create table if not exists registro.config (
  id          int primary key default 1 check (id = 1),
  clave_hash  text,
  actualizada timestamptz not null default now()
);
insert into registro.config (id) values (1) on conflict do nothing;

create table if not exists registro.fallos (            -- intentos de clave fallidos (límite anti fuerza bruta)
  ts timestamptz not null default now()
);
create index if not exists fallos_ts on registro.fallos (ts);

create table if not exists registro.personas (
  id     uuid primary key default gen_random_uuid(),
  nombre text not null check (length(btrim(nombre)) between 1 and 60),
  grupo  text not null default 'Operario' check (grupo in ('Jefe', 'Operario', 'Otro')),
  activo boolean not null default true,
  creada timestamptz not null default now()
);
create unique index if not exists personas_nombre_uk on registro.personas (lower(btrim(nombre)));

create table if not exists registro.dispositivos (
  id     uuid primary key default gen_random_uuid(),
  nombre text not null check (length(btrim(nombre)) between 1 and 80),
  grupo  text not null default 'Otro'
         check (grupo in ('Máquina', 'Móvil / lector', 'Ordenador', 'Impresora', 'Otro')),
  serie  text,
  activo boolean not null default true,
  tiene  text,                       -- quién lo tiene ahora (null = libre)
  desde  timestamptz,                -- desde cuándo lo tiene
  orden  int not null default 0,
  creado timestamptz not null default now(),
  check ((tiene is null) = (desde is null))
);
create unique index if not exists dispositivos_nombre_uk on registro.dispositivos (lower(btrim(nombre)));

create table if not exists registro.movimientos (
  id             bigint generated always as identity primary key,
  ts             timestamptz not null default now(),
  dispositivo_id uuid not null references registro.dispositivos (id),
  dispositivo    text not null,      -- nombre en ese momento
  persona        text not null,      -- quién lo cogió / quién lo tenía y lo deja
  accion         text not null check (accion in ('coger', 'dejar')),
  nota           text,
  por            text,               -- quién lo registró (si no es la propia persona)
  automatico     boolean not null default false,   -- «dejar» automático al pasar el dispositivo de una persona a otra
  desde          timestamptz         -- en «dejar»: desde cuándo lo tenía
);
create index if not exists movimientos_ts      on registro.movimientos (ts desc, id desc);
create index if not exists movimientos_disp    on registro.movimientos (dispositivo_id, ts desc);
create index if not exists movimientos_persona on registro.movimientos (persona, ts desc);

alter table registro.config       enable row level security;
alter table registro.fallos       enable row level security;
alter table registro.personas     enable row level security;
alter table registro.dispositivos enable row level security;
alter table registro.movimientos  enable row level security;

-- ── Ayudas ──────────────────────────────────────────────────────────────────
create or replace function registro.grupo_dispositivo(p text) returns text
language sql immutable set search_path = pg_catalog as $$
  select case
    when t like '%maq%' or t like '%transpal%' or t like '%retract%' or t like '%elevad%' or t like '%torito%' then 'Máquina'
    when t like '%ordenador%' or t like '%sobremesa%' or t like '%thin%' or t like '%portatil%' or t like '%todo en uno%' or t = 'pc' then 'Ordenador'
    when t like '%movil%' or t like '%lector%' or t like '%pistola%' or t like '%tablet%' then 'Móvil / lector'
    when t like '%impres%' or t like '%zebra%' then 'Impresora'
    else 'Otro' end
  from (select translate(lower(btrim(coalesce(p, ''))), 'áéíóúü', 'aeiouu') as t) x;
$$;

create or replace function registro.grupo_persona(p text) returns text
language sql immutable set search_path = pg_catalog as $$
  select case
    when t like 'jefe%' then 'Jefe'
    when t like 'operari%' then 'Operario'
    else 'Otro' end
  from (select lower(btrim(coalesce(p, ''))) as t) x;
$$;

-- null = clave correcta; si no, el motivo del rechazo
create or replace function registro.comprobar_clave(p_clave text) returns text
language plpgsql security definer set search_path = registro, extensions, pg_temp as $$
declare v_hash text; v_fallos int;
begin
  select clave_hash into v_hash from registro.config where id = 1;
  if v_hash is null then return 'sin_clave'; end if;
  select count(*) into v_fallos from registro.fallos where ts > now() - interval '10 minutes';
  if v_fallos >= 50 then return 'bloqueado'; end if;
  if p_clave is null or p_clave = '' or length(p_clave) > 200 or crypt(p_clave, v_hash) <> v_hash then
    insert into registro.fallos default values;
    delete from registro.fallos where ts < now() - interval '1 day';
    return 'clave';
  end if;
  return null;
end $$;

-- Lo que ve la pantalla: todos los dispositivos y personas (los archivados llevan activo=false)
create or replace function registro.estado() returns jsonb
language sql stable security definer set search_path = registro, pg_temp as $$
  select jsonb_build_object(
    'ok', true,
    'ahora', now(),
    'dispositivos', coalesce((
      select jsonb_agg(jsonb_build_object('id', d.id, 'nombre', d.nombre, 'grupo', d.grupo, 'serie', d.serie,
                                          'activo', d.activo, 'tiene', d.tiene, 'desde', d.desde)
                       order by d.activo desc, d.grupo, d.orden, d.nombre)
        from registro.dispositivos d), '[]'::jsonb),
    'personas', coalesce((
      select jsonb_agg(jsonb_build_object('id', p.id, 'nombre', p.nombre, 'grupo', p.grupo, 'activo', p.activo)
                       order by p.activo desc, case p.grupo when 'Jefe' then 0 when 'Operario' then 1 else 2 end, p.nombre)
        from registro.personas p), '[]'::jsonb)
  );
$$;

-- ── Coger / dejar ───────────────────────────────────────────────────────────
create or replace function registro.a_coger(a jsonb) returns jsonb
language plpgsql security definer set search_path = registro, pg_temp as $$
declare
  d        registro.dispositivos%rowtype;
  v_pers   text;
  v_nota   text := nullif(left(btrim(coalesce(a->>'nota', '')), 200), '');
  v_forzar boolean := coalesce((a->>'forzar')::boolean, false);
  v_ahora  timestamptz := clock_timestamp();
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

  if d.tiene is not null then
    if not v_forzar then
      return registro.estado() || jsonb_build_object('ok', false, 'codigo', 'ocupado',
               'error', 'Ya lo tiene ' || d.tiene || '.', 'tiene', d.tiene, 'desde', d.desde);
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
  v_ahora timestamptz := clock_timestamp();
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

  insert into registro.movimientos (ts, dispositivo_id, dispositivo, persona, accion, nota, por, desde)
  values (v_ahora, d.id, d.nombre, d.tiene, 'dejar', v_nota,
          case when lower(v_por) = lower(d.tiene) then null else v_por end, d.desde);
  update registro.dispositivos set tiene = null, desde = null where id = d.id;
  return registro.estado();
end $$;

-- ── Historial (también sirve para exportar: p_max = 5000) ───────────────────
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
  if v_acc is not null and v_acc not in ('coger', 'dejar') then raise exception 'Filtro de acción no válido.'; end if;
  if nullif(a->>'desde', '') is not null then
    v_desde := ((a->>'desde')::date)::timestamp at time zone 'Europe/Madrid';
  end if;
  if nullif(a->>'hasta', '') is not null then
    v_hasta := (((a->>'hasta')::date) + 1)::timestamp at time zone 'Europe/Madrid';
  end if;

  select coalesce(jsonb_agg(to_jsonb(t) order by t.ts desc, t.id desc), '[]'::jsonb) into v_filas
    from (select m.id, m.ts, m.dispositivo, m.persona, m.accion, m.nota, m.por, m.automatico, m.desde
            from registro.movimientos m
           where (v_disp  is null or m.dispositivo_id = v_disp)
             and (v_pers  is null or lower(m.persona) = lower(v_pers))
             and (v_acc   is null or m.accion = v_acc)
             and (v_desde is null or m.ts >= v_desde)
             and (v_hasta is null or m.ts <  v_hasta)
           order by m.ts desc, m.id desc
           limit v_lim + 1 offset v_off) t;

  v_mas := jsonb_array_length(v_filas) > v_lim;
  if v_mas then v_filas := v_filas - v_lim; end if;        -- quita la fila de más (índice v_lim)
  return jsonb_build_object('ok', true, 'filas', v_filas, 'mas', v_mas);
end $$;

-- ── Ajustes: dispositivos ───────────────────────────────────────────────────
create or replace function registro.a_guardar_dispositivo(a jsonb) returns jsonb
language plpgsql security definer set search_path = registro, pg_temp as $$
declare
  v_id  uuid := nullif(a->>'id', '')::uuid;
  v_nom text := left(btrim(coalesce(a->>'nombre', '')), 80);
  v_grp text := registro.grupo_dispositivo(a->>'grupo');
  v_ser text := nullif(left(btrim(coalesce(a->>'serie', '')), 80), '');
begin
  if v_nom = '' then raise exception 'Falta el nombre.'; end if;
  if v_id is null then
    insert into registro.dispositivos (nombre, grupo, serie) values (v_nom, v_grp, v_ser);
  else
    update registro.dispositivos set nombre = v_nom, grupo = v_grp, serie = v_ser where id = v_id;
    if not found then raise exception 'No encuentro ese dispositivo.'; end if;
  end if;
  return registro.estado();
exception when unique_violation then
  raise exception 'Ya hay un dispositivo con ese nombre.';
end $$;

create or replace function registro.a_archivar_dispositivo(a jsonb) returns jsonb
language plpgsql security definer set search_path = registro, pg_temp as $$
declare d registro.dispositivos%rowtype; v_activo boolean := coalesce((a->>'activo')::boolean, true);
begin
  select * into d from registro.dispositivos where id = (a->>'id')::uuid for update;
  if not found then raise exception 'No encuentro ese dispositivo.'; end if;
  if not v_activo and d.tiene is not null then
    raise exception 'Lo tiene % ahora: primero hay que dejarlo.', d.tiene;
  end if;
  update registro.dispositivos set activo = v_activo where id = d.id;
  return registro.estado();
end $$;

create or replace function registro.a_importar_dispositivos(a jsonb) returns jsonb
language plpgsql security definer set search_path = registro, pg_temp as $$
declare l jsonb; v_nom text; v_n int; v_nuevos int := 0; v_ya int := 0;
begin
  if jsonb_typeof(a->'lineas') is distinct from 'array' then raise exception 'Faltan las líneas a importar.'; end if;
  if jsonb_array_length(a->'lineas') > 500 then raise exception 'Máximo 500 líneas por importación.'; end if;
  for l in select * from jsonb_array_elements(a->'lineas') loop
    v_nom := left(btrim(coalesce(l->>'nombre', '')), 80);
    continue when v_nom = '';
    insert into registro.dispositivos (nombre, grupo, serie)
    values (v_nom, registro.grupo_dispositivo(l->>'grupo'), nullif(left(btrim(coalesce(l->>'serie', '')), 80), ''))
    on conflict (lower(btrim(nombre))) do nothing;
    get diagnostics v_n = row_count;
    if v_n = 1 then v_nuevos := v_nuevos + 1; else v_ya := v_ya + 1; end if;
  end loop;
  return registro.estado() || jsonb_build_object('nuevos', v_nuevos, 'existentes', v_ya);
end $$;

-- ── Ajustes: personas ───────────────────────────────────────────────────────
create or replace function registro.a_guardar_persona(a jsonb) returns jsonb
language plpgsql security definer set search_path = registro, pg_temp as $$
declare
  v_id  uuid := nullif(a->>'id', '')::uuid;
  v_nom text := left(btrim(coalesce(a->>'nombre', '')), 60);
  v_grp text := registro.grupo_persona(a->>'grupo');
  v_ant text;
begin
  if v_nom = '' then raise exception 'Falta el nombre.'; end if;
  if v_id is null then
    insert into registro.personas (nombre, grupo) values (v_nom, v_grp);
  else
    select nombre into v_ant from registro.personas where id = v_id for update;
    if not found then raise exception 'No encuentro a esa persona.'; end if;
    update registro.personas set nombre = v_nom, grupo = v_grp where id = v_id;
    update registro.dispositivos set tiene = v_nom where tiene is not null and lower(tiene) = lower(v_ant);
  end if;
  return registro.estado();
exception when unique_violation then
  raise exception 'Ya hay una persona con ese nombre.';
end $$;

create or replace function registro.a_archivar_persona(a jsonb) returns jsonb
language plpgsql security definer set search_path = registro, pg_temp as $$
begin
  update registro.personas set activo = coalesce((a->>'activo')::boolean, true) where id = (a->>'id')::uuid;
  if not found then raise exception 'No encuentro a esa persona.'; end if;
  return registro.estado();
end $$;

create or replace function registro.a_importar_personas(a jsonb) returns jsonb
language plpgsql security definer set search_path = registro, pg_temp as $$
declare l jsonb; v_nom text; v_n int; v_nuevos int := 0; v_ya int := 0;
begin
  if jsonb_typeof(a->'lineas') is distinct from 'array' then raise exception 'Faltan las líneas a importar.'; end if;
  if jsonb_array_length(a->'lineas') > 500 then raise exception 'Máximo 500 líneas por importación.'; end if;
  for l in select * from jsonb_array_elements(a->'lineas') loop
    v_nom := left(btrim(coalesce(l->>'nombre', '')), 60);
    continue when v_nom = '';
    insert into registro.personas (nombre, grupo) values (v_nom, registro.grupo_persona(l->>'grupo'))
    on conflict (lower(btrim(nombre))) do nothing;
    get diagnostics v_n = row_count;
    if v_n = 1 then v_nuevos := v_nuevos + 1; else v_ya := v_ya + 1; end if;
  end loop;
  return registro.estado() || jsonb_build_object('nuevos', v_nuevos, 'existentes', v_ya);
end $$;

-- ── Clave ───────────────────────────────────────────────────────────────────
create or replace function registro.a_cambiar_clave(a jsonb) returns jsonb
language plpgsql security definer set search_path = registro, extensions, pg_temp as $$
declare v_nueva text := coalesce(a->>'nueva', '');
begin
  if length(v_nueva) < 8 or length(v_nueva) > 64 then raise exception 'La clave nueva debe tener entre 8 y 64 caracteres.'; end if;
  update registro.config set clave_hash = crypt(v_nueva, gen_salt('bf', 10)), actualizada = now() where id = 1;
  delete from registro.fallos;
  return jsonb_build_object('ok', true);
end $$;

-- ── La única puerta ─────────────────────────────────────────────────────────
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

  begin
    v_res := case p_accion
      when 'comprobar'             then jsonb_build_object('ok', true)
      when 'estado'                then registro.estado()
      when 'coger'                 then registro.a_coger(v_args)
      when 'dejar'                 then registro.a_dejar(v_args)
      when 'historial'             then registro.a_historial(v_args, 200)
      when 'exportar'              then registro.a_historial(v_args, 5000)
      when 'guardar_dispositivo'   then registro.a_guardar_dispositivo(v_args)
      when 'archivar_dispositivo'  then registro.a_archivar_dispositivo(v_args)
      when 'importar_dispositivos' then registro.a_importar_dispositivos(v_args)
      when 'guardar_persona'       then registro.a_guardar_persona(v_args)
      when 'archivar_persona'      then registro.a_archivar_persona(v_args)
      when 'importar_personas'     then registro.a_importar_personas(v_args)
      when 'cambiar_clave'         then registro.a_cambiar_clave(v_args)
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
