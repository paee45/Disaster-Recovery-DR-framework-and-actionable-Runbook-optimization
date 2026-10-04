-- Seed for the local "RDS" Postgres containers. psql vars: :orders, :payments, :app_pw, :hb_age
CREATE ROLE app_user LOGIN PASSWORD :'app_pw';
CREATE DATABASE app OWNER app_user;
\connect app
CREATE SCHEMA dr AUTHORIZATION app_user;
CREATE TABLE public.orders   (id bigserial PRIMARY KEY, created_at timestamptz NOT NULL DEFAULT now(), amount numeric);
CREATE TABLE public.payments (id bigserial PRIMARY KEY, created_at timestamptz NOT NULL DEFAULT now(), order_id bigint);
CREATE TABLE dr.heartbeat (id int PRIMARY KEY, ts timestamptz NOT NULL, src text);
INSERT INTO public.orders(created_at, amount)   SELECT now() - make_interval(mins => :orders - g), g FROM generate_series(1, :orders) g;
INSERT INTO public.payments(created_at, order_id) SELECT now() - make_interval(mins => :payments - g), g FROM generate_series(1, :payments) g;
INSERT INTO dr.heartbeat VALUES (1, now() - make_interval(mins => :hb_age), 'seed');
ALTER TABLE public.orders OWNER TO app_user; ALTER TABLE public.payments OWNER TO app_user; ALTER TABLE dr.heartbeat OWNER TO app_user;
