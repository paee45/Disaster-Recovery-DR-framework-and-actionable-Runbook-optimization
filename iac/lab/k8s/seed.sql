-- DR lab seed (idempotent). Run as the RDS master user against database postgres; :pw = app_user password.
SELECT NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'app_user') AS need_role \gset
\if :need_role
CREATE ROLE app_user LOGIN;
\endif
ALTER ROLE app_user PASSWORD :'pw';
SELECT NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = 'app') AS need_db \gset
\if :need_db
CREATE DATABASE app OWNER app_user;
\endif
\connect app
CREATE SCHEMA IF NOT EXISTS dr AUTHORIZATION app_user;
CREATE TABLE IF NOT EXISTS public.orders   (id bigserial PRIMARY KEY, created_at timestamptz NOT NULL DEFAULT now(), amount numeric);
CREATE TABLE IF NOT EXISTS public.payments (id bigserial PRIMARY KEY, created_at timestamptz NOT NULL DEFAULT now(), order_id bigint);
CREATE TABLE IF NOT EXISTS dr.heartbeat (id int PRIMARY KEY, ts timestamptz NOT NULL, src text);
INSERT INTO public.orders(created_at, amount) SELECT now() - make_interval(mins => 500 - g), g FROM generate_series(1, 500) g WHERE NOT EXISTS (SELECT 1 FROM public.orders);
INSERT INTO public.payments(created_at, order_id) SELECT now() - make_interval(mins => 300 - g), g FROM generate_series(1, 300) g WHERE NOT EXISTS (SELECT 1 FROM public.payments);
INSERT INTO dr.heartbeat VALUES (1, now(), 'dr-lab-seed') ON CONFLICT (id) DO UPDATE SET ts = now();
ALTER TABLE public.orders OWNER TO app_user; ALTER TABLE public.payments OWNER TO app_user; ALTER TABLE dr.heartbeat OWNER TO app_user;
SELECT 'seeded: orders=' || (SELECT count(*) FROM public.orders) || ' payments=' || (SELECT count(*) FROM public.payments);
