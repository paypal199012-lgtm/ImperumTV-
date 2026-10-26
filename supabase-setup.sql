-- ImperumTV: Datenbank für die Playlist-Website (MAC-Adresse + Device Key)
-- In Supabase unter "SQL Editor" komplett einfügen und auf "Run" klicken.
-- Achtung: Ein älterer Stand dieser Tabelle wird dabei gelöscht und neu angelegt.

drop function if exists public.register_device(text);
drop function if exists public.set_playlist(text, text, text, text, text);
drop function if exists public.get_playlist(text);
drop function if exists public.register_device(text, text);
drop function if exists public.set_playlist(text, text, text, text, text, text);
drop function if exists public.get_playlist(text, text);
drop table if exists public.devices;

create table public.devices (
  mac        text primary key,
  device_key text not null,
  m3u_url    text,
  server     text,
  username   text,
  password   text,
  created_at timestamptz not null default now(),
  updated_at timestamptz
);

-- Niemand darf die Tabelle direkt lesen oder ändern, nur über die Funktionen unten
alter table public.devices enable row level security;
revoke all on table public.devices from anon, authenticated;

-- App meldet MAC-Adresse und Device Key an
create function public.register_device(p_mac text, p_key text)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if upper(p_mac) !~ '^([0-9A-F]{2}:){5}[0-9A-F]{2}$' or p_key !~ '^[0-9]{6}$' then
    raise exception 'Ungültige Gerätedaten';
  end if;
  insert into devices (mac, device_key) values (upper(p_mac), p_key)
  on conflict (mac) do nothing;
end;
$$;

-- Website trägt die Playlist ein (nur mit passender MAC-Adresse UND Device Key)
create function public.set_playlist(
  p_mac text, p_key text, p_m3u text, p_server text, p_username text, p_password text
)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
begin
  update devices set
    m3u_url    = nullif(trim(p_m3u), ''),
    server     = nullif(trim(p_server), ''),
    username   = nullif(trim(p_username), ''),
    password   = nullif(trim(p_password), ''),
    updated_at = now()
  where mac = upper(trim(p_mac)) and device_key = trim(p_key);
  return found;
end;
$$;

-- App holt ihre Playlist ab
create function public.get_playlist(p_mac text, p_key text)
returns table (m3u_url text, server text, username text, password text, updated_at timestamptz)
language sql
stable
security definer
set search_path = public
as $$
  select d.m3u_url, d.server, d.username, d.password, d.updated_at
  from devices d
  where d.mac = upper(p_mac) and d.device_key = p_key;
$$;

revoke all on function public.register_device(text, text) from public;
revoke all on function public.set_playlist(text, text, text, text, text, text) from public;
revoke all on function public.get_playlist(text, text) from public;
grant execute on function public.register_device(text, text) to anon, authenticated;
grant execute on function public.set_playlist(text, text, text, text, text, text) to anon, authenticated;
grant execute on function public.get_playlist(text, text) to anon, authenticated;
