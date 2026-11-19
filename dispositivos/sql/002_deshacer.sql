-- Deshace 001_registro_dispositivos.sql. BORRA el esquema «registro» con todo su contenido
-- (dispositivos, personas e historial). Solo si de verdad se quiere quitar la herramienta.
drop function if exists public.rd_accion(text, text, jsonb);
drop schema if exists registro cascade;
