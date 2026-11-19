-- Deshace 007_mejoras.sql y vuelve a lo de 003.
-- ANTES hay que volver a ejecutar, por este orden, 001_registro_dispositivos.sql y 003_pin_y_avisos.sql (son re-ejecutables y
-- dejan otra vez las funciones estado, a_coger, a_dejar, a_avisar y rd_accion como estaban). Después, este archivo.
-- Se pierden las marcas de «fuera de servicio» y su registro; los movimientos y avisos no se tocan.
drop function if exists registro.a_pasar(jsonb);
drop function if exists registro.a_fuera_servicio(jsonb);
drop function if exists registro.a_estadisticas(jsonb);
drop function if exists registro.ts_movimiento(jsonb, uuid);
drop function if exists registro.cuando_valido(jsonb);
drop table if exists registro.fuera_log;
alter table registro.dispositivos
  drop column if exists fuera, drop column if exists fuera_motivo, drop column if exists fuera_desde, drop column if exists fuera_por;
