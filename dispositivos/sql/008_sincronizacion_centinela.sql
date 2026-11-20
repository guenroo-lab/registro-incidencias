-- ============================================================================
-- Registro de dispositivos (Anubis) · 008: estados + sincronización con Centinela.
--
-- · Estado de cada dispositivo o máquina: operativo · con fallo (solo máquinas: se puede coger, sale un aviso) · averiado y en
--   reparación (NO se puede coger) · baja (solo dispositivos: desaparece de las listas; el historial se conserva).
--   «Fuera de servicio» (007) pasa a ser lo mismo que averiado: la columna `fuera` se mantiene sola a partir del estado.
-- · Un jefe cambia el estado con pulsación larga sobre el cuadro (acción `cambiar_estado`, con el PIN de jefes).
-- · Centinela (pestañas Dispositivos y Maquinaria, Google Sheets) es la fuente de las altas y de los estados: su sincronizador llama a
--   `sync_centinela` (con el PIN) y manda lo que hay en sus hojas; Anubis responde con los cambios de estado que se han hecho aquí y
--   que Centinela todavía no ha reflejado (cola `cambios_estado`), y Centinela los confirma en la siguiente llamada.
--   Mientras un cambio hecho en Anubis esté pendiente, lo que mande Centinela NO lo pisa (gana el cambio más reciente).
--   Vincular por primera vez: por (origen, origen_id); si no, por número de serie con un dispositivo aún sin vincular.
--   Anubis NUNCA toca quién tiene qué ni los movimientos: eso es solo de Anubis.
--
-- Requiere 001, 003 y 007. Se puede volver a ejecutar sin romper nada. Para deshacer: 008_deshacer.sql.
-- ============================================================================

-- ── Columnas ────────────────────────────────────────────────────────────────
alter table registro.dispositivos
  add column if not exists estado       text not null default 'operativo',
  add column if not exists estado_nota  text,
  add column if not exists estado_desde timestamptz,
  add column if not exists estado_por   text,
  add column if not exists origen       text,
  add column if not exists origen_id    text;

do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'dispositivos_estado_ck') then
    alter table registro.dispositivos add constraint dispositivos_estado_ck
      check (estado in ('operativo', 'fallo', 'averiado', 'reparacion', 'baja'));
  end if;
  if not exists (select 1 from pg_constraint where conname = 'dispositivos_origen_ck') then
    alter table registro.dispositivos add constraint dispositivos_origen_ck
      check ((origen is null and origen_id is null) or (origen in ('dispositivos', 'maquinaria') and length(btrim(origen_id)) between 1 and 40));
  end if;
end $$;
create unique index if not exists dispositivos_origen_uk on registro.dispositivos (origen, origen_id) where origen is not null;

-- lo que ya estaba «fuera de servicio» (007) pasa a averiado
update registro.dispositivos
   set estado = 'averiado', estado_nota = fuera_motivo, estado_desde = fuera_desde, estado_por = fuera_por
 where fuera and estado = 'operativo';

-- ── Registro de cambios de estado (y cola para Centinela) ───────────────────
create table if not exists registro.cambios_estado (
  id              bigint generated always as identity primary key,
  ts              timestamptz not null default now(),
  dispositivo_id  uuid not null references registro.dispositivos (id),
  origen          text,
  origen_id       text,
  estado_anterior text,
  estado          text not null,
  nota            text,
  por             text not null,
  fuente          text not null check (fuente in ('anubis', 'centinela')),
  aplicado        boolean not null default false,   -- true = Centinela ya lo ha reflejado en sus hojas (o no hacía falta)
  aplicado_ts     timestamptz,
  resultado       text
);
create index if not exists cambios_estado_pend on registro.cambios_estado (id) where not aplicado;
create index if not exists cambios_estado_disp on registro.cambios_estado (dispositivo_id, id desc);
alter table registro.cambios_estado enable row level security;

-- ── Qué estados admite cada cosa (es el vocabulario de Centinela) ────────────
-- Maquinaria de Centinela: OK / Fallas / Averiada / En revisión. Dispositivos de Centinela: Operativo / Averiado / En reparación / Baja.
create or replace function registro.estados_permitidos(p_grupo text, p_origen text) returns text[]
language sql immutable set search_path = pg_temp as $$
  select case
    when p_origen = 'maquinaria' or (p_origen is null and p_grupo = 'Máquina') then array['operativo', 'fallo', 'averiado', 'reparacion']
    else array['operativo', 'averiado', 'reparacion', 'baja'] end;
$$;

-- ── Estado: ahora cada dispositivo trae su estado y si Centinela aún no lo ha reflejado ─────────────
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
                                          'estado', d.estado, 'estado_nota', d.estado_nota, 'estado_desde', d.estado_desde,
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

-- ── Aplicar un estado a una fila (lo usan Anubis y la sincronización) ───────
-- Mantiene `fuera` (averiado y en reparación bloquean), `activo` (baja lo quita de las listas y la reactivación lo devuelve),
-- el registro de paradas (fuera_log) y suelta el dispositivo si alguien lo tenía al darlo de baja. NO decide quién puede hacerlo
-- ni valida el estado: eso lo hace quien la llama.
create or replace function registro.fijar_estado(p_id uuid, p_estado text, p_nota text, p_por text, p_fuente text) returns void
language plpgsql security definer set search_path = registro, pg_temp as $$
declare
  d       registro.dispositivos%rowtype;
  v_fuera boolean := p_estado in ('averiado', 'reparacion');
  v_nota  text := nullif(left(btrim(coalesce(p_nota, '')), 200), '');
  v_ts    timestamptz;
begin
  select * into d from registro.dispositivos where id = p_id for update;
  if not found then return; end if;

  if p_estado = 'baja' and d.tiene is not null then
    v_ts := registro.ts_movimiento('{}'::jsonb, d.id);
    insert into registro.movimientos (ts, dispositivo_id, dispositivo, persona, accion, nota, por, automatico, desde)
    values (v_ts, d.id, d.nombre, d.tiene, 'dejar', 'Dado de baja', p_por, true, d.desde);
  end if;

  update registro.dispositivos set
    estado       = p_estado,
    estado_nota  = case when p_estado = 'operativo' then null else v_nota end,
    estado_desde = case when p_estado = d.estado and d.estado_desde is not null then d.estado_desde else clock_timestamp() end,
    estado_por   = p_por,
    fuera        = v_fuera,
    fuera_motivo = case when v_fuera then coalesce(v_nota, d.fuera_motivo) else null end,
    fuera_desde  = case when v_fuera then case when d.fuera then d.fuera_desde else clock_timestamp() end else null end,
    fuera_por    = case when v_fuera then p_por else null end,
    activo       = case when p_estado = 'baja' then false when d.estado = 'baja' then true else d.activo end,
    tiene        = case when p_estado = 'baja' then null else d.tiene end,
    desde        = case when p_estado = 'baja' then null else d.desde end
   where id = d.id;

  if v_fuera and not d.fuera then
    insert into registro.fuera_log (dispositivo_id, dispositivo, accion, motivo, por) values (d.id, d.nombre, 'fuera', v_nota, p_por);
  elsif not v_fuera and d.fuera then
    insert into registro.fuera_log (dispositivo_id, dispositivo, accion, motivo, por) values (d.id, d.nombre, 'servicio', v_nota, p_por);
  end if;

  if p_estado is distinct from d.estado or v_nota is distinct from d.estado_nota then
    insert into registro.cambios_estado (dispositivo_id, origen, origen_id, estado_anterior, estado, nota, por, fuente, aplicado, aplicado_ts)
    values (d.id, d.origen, d.origen_id, d.estado, p_estado, v_nota, p_por, p_fuente,
            p_fuente <> 'anubis' or d.origen is null,           -- lo de Centinela ya está en Centinela; lo que no está vinculado no tiene nada que reflejar
            case when p_fuente <> 'anubis' or d.origen is null then clock_timestamp() end);
  end if;
end $$;

-- ── Cambiar el estado desde Anubis (pulsación larga) ────────────────────────
-- args: dispositivo_id, persona (quién lo hace, de la lista), estado, nota (obligatoria, mínimo 5, salvo al volver a operativo o dar de baja)
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
    raise exception 'Escribe qué le pasa (mínimo 5 letras).';
  end if;
  if v_est = 'operativo' then v_nota := null; end if;

  if d.estado = v_est and d.estado_nota is not distinct from v_nota then
    return registro.estado() || jsonb_build_object('ya', true);
  end if;

  perform registro.fijar_estado(d.id, v_est, v_nota, v_por, 'anubis');
  return registro.estado();
end $$;

-- «Fuera de servicio» (007) = averiado. Se mantiene la acción por si queda una web antigua abierta.
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
    perform registro.fijar_estado(d.id, 'averiado', v_motivo, v_por, 'anubis');
  else
    if not d.fuera then return registro.estado() || jsonb_build_object('ya', true); end if;
    perform registro.fijar_estado(d.id, 'operativo', v_motivo, v_por, 'anubis');
  end if;
  return registro.estado();
end $$;

-- ── Sincronización con Centinela ────────────────────────────────────────────
-- args:
--   items   [{origen: 'dispositivos'|'maquinaria', origen_id, nombre, grupo, serie, estado, nota}]  (hasta 500; el estado en el vocabulario de Anubis)
--   acks    [{id, ok, error}]  cambios de la cola que Centinela ya ha reflejado (ok=false: no pudo; no se reintenta, Centinela manda)
--   simular true = no escribe nada, solo cuenta lo que haría
--   crear   {maquinaria: true, dispositivos: false}  qué altas nuevas se aceptan (por defecto, máquinas sí y dispositivos no: los móviles de Centinela
--           pueden llevar el IMEI como «serie» y no coincidir con la serie de Anubis; hasta que un jefe de área lo active, solo se vinculan los que coinciden)
-- devuelve {ok, resumen:{vinculados, creados, estados, sin_cambio, esperando, ignorados, sin_vincular}, sin_vincular:[{origen, origen_id, nombre, serie}],
--           pendientes:[{id, origen, origen_id, estado, nota, por, ts, dispositivo}]}
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
                                                  'nota', c.nota, 'por', c.por, 'ts', c.ts, 'dispositivo', x.nombre) order by c.id), '[]'::jsonb)
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

-- ── Puerta única: igual que en 007 + cambiar_estado y sync_centinela (las dos piden el PIN de jefes) ───────
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
                           'fuera_servicio', 'estadisticas', 'cambiar_estado', 'sync_centinela',
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
