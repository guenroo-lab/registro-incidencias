-- Deshace 009_estado_sin_pin_con_razon.sql y vuelve a lo de 008.
-- 1) Este archivo: devuelve el historial a solo movimientos (coger / dejar).
-- 2) Después, volver a ejecutar 008_sincronizacion_centinela.sql (es re-ejecutable): deja otra vez estado(), a_cambiar_estado,
--    a_sync_centinela y rd_accion como estaban (cambiar_estado y fuera_servicio vuelven a pedir el PIN de jefes).
-- Los datos no se tocan: las razones ya guardadas se quedan en `cambios_estado.nota`.
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
