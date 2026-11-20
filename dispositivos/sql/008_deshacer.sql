-- Deshace 008_sincronizacion_centinela.sql y vuelve a lo de 007.
-- ANTES hay que volver a ejecutar 007_mejoras.sql (es re-ejecutable y deja otra vez estado, a_fuera_servicio y rd_accion como estaban).
-- Después, este archivo. Se pierden los estados (averiado, con fallo, baja…) y el vínculo con Centinela; lo que está «fuera de servicio»
-- (fuera = true) sigue fuera. Lo dado de baja se queda archivado (activo = false). Movimientos y avisos no se tocan.
drop function if exists registro.a_sync_centinela(jsonb);
drop function if exists registro.a_cambiar_estado(jsonb);
drop function if exists registro.fijar_estado(uuid, text, text, text, text);
drop function if exists registro.estados_permitidos(text, text);
drop table if exists registro.cambios_estado;
drop index if exists registro.dispositivos_origen_uk;
alter table registro.dispositivos drop constraint if exists dispositivos_estado_ck;
alter table registro.dispositivos drop constraint if exists dispositivos_origen_ck;
alter table registro.dispositivos
  drop column if exists estado, drop column if exists estado_nota, drop column if exists estado_desde,
  drop column if exists estado_por, drop column if exists origen, drop column if exists origen_id;
