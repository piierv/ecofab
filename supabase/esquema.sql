-- =====================================================================
-- EcoFab Lab · Esquema de Supabase
-- Pegar completo en Supabase > SQL Editor y ejecutar una sola vez.
-- Antes de ejecutar, cambia el TOKEN DEL SENSOR (sección 8).
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Tablas
-- ---------------------------------------------------------------------
create table public.contenedores (
  id              text primary key check (id in ('A','B','C','D')),
  nombre          text not null,
  nombre_completo text not null,
  ubicacion       text not null,
  gestor          text not null,
  capacidad_kg    numeric not null,
  capacidad_l     numeric not null,
  fisico          boolean not null default false,   -- true = contenedor real con sensor
  solo_operador   boolean not null default false,
  kg              numeric not null default 0,       -- acumulado por registros
  vol_pct         numeric not null default 0,       -- volumen estimado por registros
  sensor_pct      numeric,                          -- última lectura del sensor (0-100)
  sensor_dist     numeric,                          -- distancia medida en cm
  sensor_fuente   text,                             -- 'esp32' o 'manual'
  sensor_ts       timestamptz,
  pct             numeric not null default 0,       -- nivel que muestran las apps
  actualizado     timestamptz not null default now()
);

create table public.materiales (
  clave          text primary key,
  contenedor     text not null references public.contenedores(id),
  litros_por_kg  numeric not null
);

create table public.registros (
  id           uuid primary key default gen_random_uuid(),
  creado       timestamptz not null default now(),
  material     text not null references public.materiales(clave),
  submaterial  text not null default '' check (char_length(submaterial) <= 30),
  origen       text not null check (char_length(origen) between 1 and 60),
  maquina      text not null check (char_length(maquina) between 1 and 60),
  gramos       numeric not null check (gramos > 0 and gramos <= 5000),
  estimado     boolean not null default false,
  contenedor   text not null references public.contenedores(id),
  intentos     int not null default 1 check (intentos between 1 and 10),
  via_operador boolean not null default false
);
create index registros_creado_idx on public.registros (creado desc);

create table public.avisos (
  id         bigint generated always as identity primary key,
  creado     timestamptz not null default now(),
  contenedor text not null references public.contenedores(id),
  nivel      text not null check (nivel in ('warn','full')),
  texto      text not null
);

create table public.retiros (
  id             bigint generated always as identity primary key,
  creado         timestamptz not null default now(),
  contenedor     text not null references public.contenedores(id),
  kg             numeric not null,
  pct            numeric not null,
  gestor         text not null,
  registrado_por uuid references auth.users(id)
);

-- Personas del laboratorio que pueden entrar al panel
create table public.staff (
  user_id uuid primary key references auth.users(id) on delete cascade,
  nombre  text
);

-- Sensores autorizados (el token se guarda como hash, nunca en texto)
create table public.dispositivos (
  id             text primary key,
  contenedor     text not null references public.contenedores(id),
  token_sha256   text not null,
  ultima_lectura timestamptz
);

-- ---------------------------------------------------------------------
-- 2. Funciones internas
-- ---------------------------------------------------------------------
create or replace function public.es_staff()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.staff where user_id = auth.uid());
$$;

-- Recalcula el nivel de un contenedor y crea avisos al cruzar 80 % y 95 %
create or replace function public._recalcular(p_id text)
returns void language plpgsql security definer set search_path = public as $$
declare
  c public.contenedores;
  antes numeric;
  despues numeric;
begin
  select * into c from public.contenedores where id = p_id for update;
  antes := c.pct;
  if c.fisico and c.sensor_pct is not null then
    despues := c.sensor_pct;
  else
    despues := least(100, greatest(c.kg / c.capacidad_kg * 100, c.vol_pct));
  end if;
  update public.contenedores set pct = round(despues, 1), actualizado = now() where id = p_id;

  if antes < 95 and despues >= 95 then
    insert into public.avisos (contenedor, nivel, texto)
    values (p_id, 'full', format('Contenedor %s está listo para retiro (%s %%). Avisar a %s.', p_id, round(despues), c.gestor));
  elsif antes < 80 and despues >= 80 then
    insert into public.avisos (contenedor, nivel, texto)
    values (p_id, 'warn', format('Contenedor %s llegó al %s %%. Conviene coordinar el retiro.', p_id, round(despues)));
  end if;
end $$;

-- Antes de guardar un registro: valida, limita abuso y fija el contenedor según el material
create or replace function public._antes_registro()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  m public.materiales;
  recientes int;
begin
  select * into m from public.materiales where clave = new.material;
  if not found then
    raise exception 'Material desconocido';
  end if;

  select count(*) into recientes from public.registros where creado > now() - interval '1 minute';
  if recientes >= 30 then
    raise exception 'Demasiados registros en poco tiempo. Intenta de nuevo en un minuto.';
  end if;

  new.id := gen_random_uuid();
  new.creado := now();
  new.contenedor := m.contenedor;
  new.via_operador := (select solo_operador from public.contenedores where id = m.contenedor);
  return new;
end $$;

-- Después de guardar un registro: suma peso y volumen al contenedor
create or replace function public._despues_registro()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  m public.materiales;
begin
  select * into m from public.materiales where clave = new.material;
  update public.contenedores
     set kg      = least(capacidad_kg * 1.05, kg + new.gramos / 1000.0),
         vol_pct = least(100, vol_pct + (new.gramos / 1000.0 * m.litros_por_kg) / capacidad_l * 100)
   where id = new.contenedor;
  perform public._recalcular(new.contenedor);
  return null;
end $$;

create trigger registros_antes   before insert on public.registros for each row execute function public._antes_registro();
create trigger registros_despues after  insert on public.registros for each row execute function public._despues_registro();

-- ---------------------------------------------------------------------
-- 3. Funciones que llaman las apps
-- ---------------------------------------------------------------------

-- Panel: registrar el retiro de un contenedor (solo equipo del laboratorio)
create or replace function public.registrar_retiro(p_contenedor text)
returns void language plpgsql security definer set search_path = public as $$
declare
  c public.contenedores;
begin
  if not public.es_staff() then
    raise exception 'Solo el equipo del laboratorio puede registrar retiros';
  end if;
  select * into c from public.contenedores where id = p_contenedor for update;
  if not found then
    raise exception 'Ese contenedor no existe';
  end if;
  insert into public.retiros (contenedor, kg, pct, gestor, registrado_por)
  values (c.id, round(c.kg, 1), round(c.pct), c.gestor, auth.uid());
  update public.contenedores
     set kg = 0, vol_pct = 0,
         pct = case when fisico and sensor_pct is not null then sensor_pct else 0 end,
         actualizado = now()
   where id = c.id;
end $$;

-- Panel: lectura de prueba del contenedor físico (mientras no hay sensor)
create or replace function public.lectura_prueba(p_pct numeric)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.es_staff() then
    raise exception 'Solo el equipo del laboratorio puede enviar lecturas de prueba';
  end if;
  if p_pct < 0 or p_pct > 100 then
    raise exception 'El porcentaje debe estar entre 0 y 100';
  end if;
  update public.contenedores
     set sensor_pct = p_pct, sensor_dist = null, sensor_fuente = 'manual', sensor_ts = now()
   where fisico;
  perform public._recalcular(id) from public.contenedores where fisico;
end $$;

-- ESP32: enviar una lectura del sensor (requiere el token del dispositivo)
create or replace function public.registrar_lectura(p_dispositivo text, p_token text, p_pct numeric, p_dist numeric)
returns void language plpgsql security definer set search_path = public as $$
declare
  d public.dispositivos;
begin
  select * into d from public.dispositivos where id = p_dispositivo;
  if not found or d.token_sha256 <> encode(sha256(convert_to(p_token, 'UTF8')), 'hex') then
    raise exception 'Dispositivo no autorizado';
  end if;
  if p_pct < 0 or p_pct > 100 then
    raise exception 'Porcentaje fuera de rango';
  end if;
  update public.dispositivos set ultima_lectura = now() where id = d.id;
  update public.contenedores
     set sensor_pct = round(p_pct, 1), sensor_dist = round(p_dist, 1), sensor_fuente = 'esp32', sensor_ts = now()
   where id = d.contenedor;
  perform public._recalcular(d.contenedor);
end $$;

-- ---------------------------------------------------------------------
-- 4. Permisos de las funciones
-- ---------------------------------------------------------------------
revoke execute on function public._recalcular(text)       from public, anon, authenticated;
revoke execute on function public._antes_registro()       from public, anon, authenticated;
revoke execute on function public._despues_registro()     from public, anon, authenticated;
revoke execute on function public.registrar_retiro(text)  from public, anon;
revoke execute on function public.lectura_prueba(numeric) from public, anon;
revoke execute on function public.registrar_lectura(text, text, numeric, numeric) from public;
grant  execute on function public.registrar_retiro(text)  to authenticated;
grant  execute on function public.lectura_prueba(numeric) to authenticated;
grant  execute on function public.registrar_lectura(text, text, numeric, numeric) to anon, authenticated;
grant  execute on function public.es_staff() to anon, authenticated;

-- ---------------------------------------------------------------------
-- 5. Reglas de seguridad (RLS)
-- ---------------------------------------------------------------------
alter table public.contenedores enable row level security;
alter table public.materiales   enable row level security;
alter table public.registros    enable row level security;
alter table public.avisos       enable row level security;
alter table public.retiros      enable row level security;
alter table public.staff        enable row level security;
alter table public.dispositivos enable row level security;

-- Cualquiera ve el nivel de los contenedores y los materiales
create policy "publico ve contenedores" on public.contenedores for select using (true);
create policy "publico ve materiales"   on public.materiales   for select using (true);

-- Cualquiera puede registrar un residuo, pero no leer registros ajenos
create policy "publico registra" on public.registros for insert to anon, authenticated with check (true);

-- Solo el equipo del laboratorio lee registros, avisos y retiros
create policy "staff lee registros" on public.registros for select to authenticated using (public.es_staff());
create policy "staff lee avisos"    on public.avisos    for select to authenticated using (public.es_staff());
create policy "staff lee retiros"   on public.retiros   for select to authenticated using (public.es_staff());
create policy "cada uno se ve en staff" on public.staff for select to authenticated using (user_id = auth.uid());
-- contenedores, dispositivos: sin políticas de escritura. Solo cambian a través de las funciones de arriba.

-- ---------------------------------------------------------------------
-- 6. Tiempo real para el panel
-- ---------------------------------------------------------------------
alter publication supabase_realtime add table public.contenedores, public.registros, public.avisos, public.retiros;

-- ---------------------------------------------------------------------
-- 7. Datos iniciales
-- ---------------------------------------------------------------------
insert into public.contenedores (id, nombre, nombre_completo, ubicacion, gestor, capacidad_kg, capacidad_l, fisico, solo_operador, kg, vol_pct, pct) values
  ('A', 'PLA', 'PLA', 'Bajo el mesón de las impresoras FDM', 'REBASE', 15, 120, true, false, 0, 0, 0),
  ('B', 'Resina endurecida', 'Resina endurecida (curada)', 'Junto a la impresora de resina', 'Gestor autorizado (por definir)', 10, 40, false, false, 2.4, 24, 24),
  ('C', 'Resina líquida y alcohol', 'Resina líquida y alcohol de lavado', 'Gabinete cerrado, solo operador', 'Gestor de residuos peligrosos', 8, 10, false, true, 4.8, 60, 60),
  ('D', 'Corte láser', 'Residuos de cortadora láser', 'Al costado de la cortadora láser', 'Por definir según material', 20, 150, false, false, 7.5, 45, 45);

insert into public.materiales (clave, contenedor, litros_por_kg) values
  ('pla', 'A', 8), ('cur', 'B', 3), ('liq', 'C', 1.1), ('las', 'D', 6);

-- ---------------------------------------------------------------------
-- 8. Sensor del contenedor A
--    Reemplaza CAMBIA-ESTE-TOKEN por una clave larga e inventada
--    (la misma que pondrás en el código del ESP32).
-- ---------------------------------------------------------------------
insert into public.dispositivos (id, contenedor, token_sha256)
values ('esp32-a', 'A', encode(sha256(convert_to('CAMBIA-ESTE-TOKEN', 'UTF8')), 'hex'));
