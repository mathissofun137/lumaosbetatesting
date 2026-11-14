-- =========================================================
-- Messages chat table: full setup with direct messages + accounts
-- + OS version config (System Settings → About This Mac / Luma BOT)
-- Run this whole file in the Supabase SQL editor.
-- =========================================================

create table if not exists public.messages (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null,
  username text not null,
  content text not null,
  created_at timestamptz not null default now(),
  channel text not null default 'general',
  pinned boolean not null default false,
  reply_to uuid null,
  image_path text null
);

-- Add any missing columns (including the x / t / ch columns the app also writes)
alter table public.messages add column if not exists user_id uuid;
alter table public.messages add column if not exists username text;
alter table public.messages add column if not exists content text;
alter table public.messages add column if not exists created_at timestamptz not null default now();
alter table public.messages add column if not exists channel text not null default 'general';
alter table public.messages add column if not exists pinned boolean not null default false;
alter table public.messages add column if not exists reply_to uuid null;
alter table public.messages add column if not exists image_path text null;
alter table public.messages add column if not exists x text;
alter table public.messages add column if not exists t timestamptz not null default now();
alter table public.messages add column if not exists ch text not null default 'general';

-- Drop every old CHECK constraint that mentions channel / ch
-- (so re-runs and bad previous constraints do not block us)
do $$
declare r record;
begin
  for r in
    select conname
    from pg_constraint
    where conrelid = 'public.messages'::regclass
      and contype = 'c'
      and (
        pg_get_constraintdef(oid) ~ '\m(channel|ch)\M'
        or conname in ('messages_channel_valid', 'messages_ch_valid')
      )
  loop
    execute format('alter table public.messages drop constraint if exists %I', r.conname);
  end loop;
end $$;

-- Keep channel / ch in sync for older rows (app writes both)
update public.messages
set channel = ch
where (channel is null or btrim(channel) = '')
  and ch is not null and btrim(ch) <> '';

update public.messages
set ch = channel
where (ch is null or btrim(ch) = '')
  and channel is not null and btrim(channel) <> '';

-- Normalize empty / null to general
update public.messages set channel = 'general' where channel is null or btrim(channel) = '';
update public.messages set ch = 'general' where ch is null or btrim(ch) = '';

-- Valid channel shapes the app uses:
--   public:  a-z0-9_- (1..32)
--   DM:      dm:<uuid>:<uuid>
--   group:   gc:<uuid>
-- Move anything else into a safe bucket so the CHECK can be added.
update public.messages
set channel = 'general',
    ch = 'general'
where not (
     channel ~ '^[a-z0-9_-]{1,32}$'
  or channel ~ '^dm:[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}:[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
  or channel ~ '^gc:[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
);

update public.messages
set ch = channel
where ch is distinct from channel;

-- Channel names (letters, numbers, - _) OR a DM channel OR a group chat
alter table public.messages
  add constraint messages_channel_valid
  check (
    channel ~ '^[a-z0-9_-]{1,32}$'
    or channel ~ '^dm:[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}:[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
    or channel ~ '^gc:[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
  );

alter table public.messages
  add constraint messages_ch_valid
  check (
    ch ~ '^[a-z0-9_-]{1,32}$'
    or ch ~ '^dm:[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}:[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
    or ch ~ '^gc:[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
  );

-- Indexes
create index if not exists messages_channel_created_at_idx
  on public.messages (channel, created_at);
create index if not exists messages_created_at_idx
  on public.messages (created_at);
create index if not exists messages_ch_t_idx
  on public.messages (ch, t);
create index if not exists messages_ch_pattern_idx
  on public.messages (ch text_pattern_ops);

-- =========================================================
-- Accounts, admin ("purple"), channels, and who can type
-- =========================================================

create table if not exists public.chat_profiles (
  user_id uuid primary key,
  username text not null
);

alter table public.chat_profiles add column if not exists avatar_url text;
alter table public.chat_profiles add column if not exists created_at timestamptz;

create table if not exists public.chat_admins (
  user_id uuid primary key
);
alter table public.chat_admins add column if not exists is_owner boolean not null default false;
alter table public.chat_admins add column if not exists perms text[] not null default '{}';

create table if not exists public.chat_channels (
  name text primary key check (name ~ '^[a-z0-9_-]{1,32}$'),
  restricted boolean not null default false,
  created_at timestamptz not null default now()
);

create table if not exists public.chat_channel_writers (
  channel text not null references public.chat_channels(name) on delete cascade on update cascade,
  user_id uuid not null,
  primary key (channel, user_id)
);

alter table public.chat_channels add column if not exists is_private boolean not null default false;

create table if not exists public.chat_channel_members (
  channel text not null references public.chat_channels(name) on delete cascade on update cascade,
  user_id uuid not null,
  primary key (channel, user_id)
);

create table if not exists public.chat_bans (
  user_id uuid primary key,
  permanent boolean not null default false,
  banned_until timestamptz null,
  reason text null,
  banned_by uuid null,
  created_at timestamptz not null default now()
);

create table if not exists public.chat_mutes (
  user_id uuid primary key,
  scope text not null check (scope in ('server', 'dm', 'both')),
  permanent boolean not null default false,
  muted_until timestamptz null,
  reason text null,
  muted_by uuid null,
  created_at timestamptz not null default now()
);

insert into public.chat_channels (name) values ('general'), ('random'), ('help'), ('off-topic')
on conflict do nothing;
-- keep any channel that already has messages
insert into public.chat_channels (name)
select distinct ch from public.messages
where ch ~ '^[a-z0-9_-]{1,32}$'
on conflict do nothing;

-- Helpers
create or replace function public.chat_is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.chat_admins where user_id = auth.uid());
$$;

create or replace function public.chat_is_owner() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.chat_admins where user_id = auth.uid() and is_owner);
$$;

-- Permissions: 'channels', 'channel_access', 'delete_messages', 'timeout', 'ban'. The owner (purple) has all of them.
create or replace function public.chat_has_perm(p text) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.chat_admins a
    where a.user_id = auth.uid() and (a.is_owner or p = any (a.perms))
  );
$$;

create or replace function public.chat_is_banned() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.chat_bans b
    where b.user_id = auth.uid() and (b.permanent or b.banned_until > now())
  );
$$;

-- Is this user timed out for this kind of chat? (c = channel name; DMs start with 'dm:')
create or replace function public.chat_is_muted(c text) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.chat_mutes m
    where m.user_id = auth.uid()
      and (m.permanent or m.muted_until > now())
      and (m.scope = 'both'
           or (m.scope = 'dm' and (c like 'dm:%' or c like 'gc:%'))
           or (m.scope = 'server' and c not like 'dm:%' and c not like 'gc:%'))
  );
$$;

-- Can this user see the channel? (private channels: admin + listed members only)
create or replace function public.chat_can_see(c text) returns boolean
language sql stable security definer set search_path = public as $$
  select case
    when public.chat_is_banned() then false
    when c like 'dm:%' then position(auth.uid()::text in c) > 0
    when c like 'gc:%' then true  -- membership enforced in app / group RPCs
    else not exists (select 1 from public.chat_channels where name = c and is_private)
         or public.chat_has_perm('channel_access')
         or exists (select 1 from public.chat_channel_members m where m.channel = c and m.user_id = auth.uid())
  end;
$$;

create or replace function public.chat_can_post(c text) returns boolean
language sql stable security definer set search_path = public as $$
  select not public.chat_is_muted(c) and case
    when public.chat_is_banned() then false
    when c like 'dm:%' then position(auth.uid()::text in c) > 0
    when c like 'gc:%' then true
    else exists (select 1 from public.chat_channels where name = c)
         and public.chat_can_see(c)
         and (
           not exists (select 1 from public.chat_channels where name = c and restricted)
           or public.chat_has_perm('channel_access')
           or exists (select 1 from public.chat_channel_writers w where w.channel = c and w.user_id = auth.uid())
         )
  end;
$$;

-- Keep profiles in sync with accounts; the account with username "purple" becomes admin
-- (only at signup, so whoever registers "purple" first is the admin).
create or replace function public.chat_sync_profile() returns trigger
language plpgsql security definer set search_path = public as $$
declare av text := nullif(new.raw_user_meta_data->>'avatar_url', '');
begin
  if av is not null and (av !~* '^https?://' or length(av) > 500) then av := null; end if;
  insert into public.chat_profiles (user_id, username, avatar_url, created_at)
  values (new.id, coalesce(new.raw_user_meta_data->>'username', split_part(new.email, '@', 1)), av, new.created_at)
  on conflict (user_id) do update set username = excluded.username, avatar_url = excluded.avatar_url;
  if tg_op = 'INSERT' and lower(split_part(new.email, '@', 1)) = 'purple' then
    insert into public.chat_admins (user_id, is_owner) values (new.id, true)
    on conflict (user_id) do update set is_owner = true;
  end if;
  return new;
end $$;

drop trigger if exists nyx_sync_profile on auth.users;
create trigger nyx_sync_profile
  after insert or update of raw_user_meta_data on auth.users
  for each row execute function public.chat_sync_profile();

-- Backfill accounts that already exist (including purple if already registered)
insert into public.chat_profiles (user_id, username, avatar_url)
select id, coalesce(raw_user_meta_data->>'username', split_part(email, '@', 1)),
       case when raw_user_meta_data->>'avatar_url' ~* '^https?://' then raw_user_meta_data->>'avatar_url' end
from auth.users
on conflict (user_id) do update set username = excluded.username, avatar_url = excluded.avatar_url;

insert into public.chat_admins (user_id, is_owner)
select id, true from auth.users where lower(split_part(email, '@', 1)) = 'purple'
on conflict (user_id) do update set is_owner = true;

update public.chat_profiles p set created_at = u.created_at
from auth.users u where u.id = p.user_id and p.created_at is null;

-- Deleting a channel deletes its messages
create or replace function public.chat_channel_deleted() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  delete from public.messages where ch = old.name or channel = old.name;
  return old;
end $$;
drop trigger if exists nyx_channel_deleted on public.chat_channels;
create trigger nyx_channel_deleted after delete on public.chat_channels
  for each row execute function public.chat_channel_deleted();

-- Row Level Security
alter table public.messages enable row level security;
alter table public.chat_profiles enable row level security;
alter table public.chat_admins enable row level security;
alter table public.chat_channels enable row level security;
alter table public.chat_channel_writers enable row level security;
alter table public.chat_channel_members enable row level security;
alter table public.chat_bans enable row level security;
alter table public.chat_mutes enable row level security;

drop policy if exists "read messages" on public.messages;
drop policy if exists "insert messages" on public.messages;
drop policy if exists "read messages (signed in)" on public.messages;
drop policy if exists "insert own messages" on public.messages;

create policy "read messages (signed in)" on public.messages
  for select to authenticated
  using (public.chat_can_see(ch));

create policy "insert own messages" on public.messages
  for insert to authenticated
  with check (user_id = auth.uid() and ch = channel and public.chat_can_post(ch));

drop policy if exists "admin deletes messages" on public.messages;
create policy "admin deletes messages" on public.messages
  for delete to authenticated using (public.chat_has_perm('delete_messages'));

drop policy if exists "read bans" on public.chat_bans;
create policy "read bans" on public.chat_bans for select to authenticated
  using (public.chat_is_admin() or user_id = auth.uid());

drop policy if exists "read mutes" on public.chat_mutes;
create policy "read mutes" on public.chat_mutes for select to authenticated
  using (public.chat_is_admin() or user_id = auth.uid());

-- Time out / un-time-out (admin only). scope: 'server', 'dm' or 'both'. hours = null means indefinite.
create or replace function public.chat_mute_user(p_target uuid, p_scope text, p_hours numeric default null, p_reason text default null)
returns void language plpgsql security definer set search_path = public as $$
declare until_ts timestamptz;
begin
  if not public.chat_has_perm('timeout') then raise exception 'You do not have permission to time people out'; end if;
  if p_scope not in ('server', 'dm', 'both') then raise exception 'Bad scope'; end if;
  if p_target = auth.uid() or exists (select 1 from public.chat_admins where user_id = p_target) then
    raise exception 'You cannot time out an admin';
  end if;
  if p_hours is not null then until_ts := now() + make_interval(secs => (p_hours * 3600)::double precision); end if;
  insert into public.chat_mutes (user_id, scope, permanent, muted_until, reason, muted_by)
  values (p_target, p_scope, p_hours is null, until_ts, p_reason, auth.uid())
  on conflict (user_id) do update
    set scope = excluded.scope, permanent = excluded.permanent, muted_until = excluded.muted_until,
        reason = excluded.reason, muted_by = excluded.muted_by, created_at = now();
end $$;

create or replace function public.chat_unmute_user(p_target uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.chat_has_perm('timeout') then raise exception 'You do not have permission to remove time outs'; end if;
  delete from public.chat_mutes where user_id = p_target;
end $$;

revoke execute on function public.chat_mute_user(uuid, text, numeric, text) from public, anon;
revoke execute on function public.chat_unmute_user(uuid) from public, anon;
grant execute on function public.chat_mute_user(uuid, text, numeric, text) to authenticated;
grant execute on function public.chat_unmute_user(uuid) to authenticated;

-- Ban / unban (admin only). hours = null means permanent.
create or replace function public.chat_ban_user(p_target uuid, p_hours numeric default null, p_reason text default null)
returns void language plpgsql security definer set search_path = public, auth as $$
declare until_ts timestamptz;
begin
  if not public.chat_has_perm('ban') then raise exception 'You do not have permission to ban people'; end if;
  if p_target = auth.uid() or exists (select 1 from public.chat_admins where user_id = p_target) then
    raise exception 'You cannot ban an admin';
  end if;
  if p_hours is not null then until_ts := now() + make_interval(secs => (p_hours * 3600)::double precision); end if;
  insert into public.chat_bans (user_id, permanent, banned_until, reason, banned_by)
  values (p_target, p_hours is null, until_ts, p_reason, auth.uid())
  on conflict (user_id) do update
    set permanent = excluded.permanent, banned_until = excluded.banned_until,
        reason = excluded.reason, banned_by = excluded.banned_by, created_at = now();
  -- also block the account itself from signing in
  update auth.users set banned_until = coalesce(until_ts, now() + interval '100 years') where id = p_target;
end $$;

create or replace function public.chat_unban_user(p_target uuid)
returns void language plpgsql security definer set search_path = public, auth as $$
begin
  if not public.chat_has_perm('ban') then raise exception 'You do not have permission to unban people'; end if;
  delete from public.chat_bans where user_id = p_target;
  update auth.users set banned_until = null where id = p_target;
end $$;

revoke execute on function public.chat_ban_user(uuid, numeric, text) from public, anon;
revoke execute on function public.chat_unban_user(uuid) from public, anon;
grant execute on function public.chat_ban_user(uuid, numeric, text) to authenticated;
grant execute on function public.chat_unban_user(uuid) to authenticated;

drop policy if exists "read profiles" on public.chat_profiles;
create policy "read profiles" on public.chat_profiles for select to authenticated using (true);

drop policy if exists "read own admin row" on public.chat_admins;
create policy "read own admin row" on public.chat_admins for select to authenticated
  using (user_id = auth.uid() or public.chat_is_owner());

-- Owner-only: make someone an admin with chosen permissions, or remove them.
create or replace function public.chat_set_admin(p_target uuid, p_perms text[])
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.chat_is_owner() then raise exception 'Only the owner can manage admins'; end if;
  if p_perms is null then p_perms := '{}'; end if;
  if not (p_perms <@ array['channels', 'channel_access', 'delete_messages', 'timeout', 'ban']) then
    raise exception 'Unknown permission';
  end if;
  if exists (select 1 from public.chat_admins where user_id = p_target and is_owner) then
    raise exception 'The owner cannot be changed';
  end if;
  insert into public.chat_admins (user_id, is_owner, perms) values (p_target, false, p_perms)
  on conflict (user_id) do update set perms = excluded.perms;
end $$;

create or replace function public.chat_remove_admin(p_target uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.chat_is_owner() then raise exception 'Only the owner can manage admins'; end if;
  delete from public.chat_admins where user_id = p_target and not is_owner;
end $$;

revoke execute on function public.chat_set_admin(uuid, text[]) from public, anon;
revoke execute on function public.chat_remove_admin(uuid) from public, anon;
grant execute on function public.chat_set_admin(uuid, text[]) to authenticated;
grant execute on function public.chat_remove_admin(uuid) to authenticated;

drop policy if exists "read channels" on public.chat_channels;
drop policy if exists "admin writes channels" on public.chat_channels;
drop policy if exists "channels insert" on public.chat_channels;
drop policy if exists "channels delete" on public.chat_channels;
drop policy if exists "channels update" on public.chat_channels;
create policy "read channels" on public.chat_channels for select to authenticated using (public.chat_can_see(name));
create policy "channels insert" on public.chat_channels for insert to authenticated
  with check (public.chat_has_perm('channels'));
create policy "channels delete" on public.chat_channels for delete to authenticated
  using (public.chat_has_perm('channels'));
create policy "channels update" on public.chat_channels for update to authenticated
  using (public.chat_has_perm('channels') or public.chat_has_perm('channel_access'))
  with check (public.chat_has_perm('channels') or public.chat_has_perm('channel_access'));

drop policy if exists "read writers" on public.chat_channel_writers;
drop policy if exists "admin writes writers" on public.chat_channel_writers;
create policy "read writers" on public.chat_channel_writers for select to authenticated using (true);
create policy "admin writes writers" on public.chat_channel_writers for all to authenticated
  using (public.chat_has_perm('channel_access')) with check (public.chat_has_perm('channel_access'));

drop policy if exists "read members" on public.chat_channel_members;
drop policy if exists "admin writes members" on public.chat_channel_members;
create policy "read members" on public.chat_channel_members for select to authenticated
  using (public.chat_is_admin() or user_id = auth.uid());
create policy "admin writes members" on public.chat_channel_members for all to authenticated
  using (public.chat_has_perm('channel_access')) with check (public.chat_has_perm('channel_access'));

-- =========================================================
-- OS version (System Settings → About This Mac)
-- Controlled by Luma BOT: version / version set … / osname set …
-- =========================================================

create table if not exists public.os_config (
  key text primary key check (key in ('name', 'version')),
  value text not null check (char_length(value) between 1 and 120),
  updated_at timestamptz not null default now(),
  updated_by uuid null
);

insert into public.os_config (key, value)
values
  ('name', 'macOS Sequoia'),
  ('version', '15.0 (Web Build)')
on conflict (key) do nothing;

alter table public.os_config enable row level security;

drop policy if exists "read os_config" on public.os_config;
create policy "read os_config" on public.os_config
  for select to authenticated
  using (true);

drop policy if exists "admin write os_config" on public.os_config;
create policy "admin write os_config" on public.os_config
  for all to authenticated
  using (public.chat_is_admin())
  with check (public.chat_is_admin());

-- Realtime (skips quietly if a table is already in the publication)
do $$ begin alter publication supabase_realtime add table public.messages;
exception when duplicate_object then null; end $$;
do $$ begin alter publication supabase_realtime add table public.chat_profiles;
exception when duplicate_object then null; end $$;
do $$ begin alter publication supabase_realtime add table public.chat_admins;
exception when duplicate_object then null; end $$;
do $$ begin alter publication supabase_realtime add table public.chat_mutes;
exception when duplicate_object then null; end $$;
do $$ begin alter publication supabase_realtime add table public.chat_bans;
exception when duplicate_object then null; end $$;
do $$ begin alter publication supabase_realtime add table public.chat_channels;
exception when duplicate_object then null; end $$;
do $$ begin alter publication supabase_realtime add table public.chat_channel_writers;
exception when duplicate_object then null; end $$;
do $$ begin alter publication supabase_realtime add table public.chat_channel_members;
exception when duplicate_object then null; end $$;
do $$ begin alter publication supabase_realtime add table public.os_config;
exception when duplicate_object then null; end $$;

-- =========================================================
-- Group chat icons
-- Adds icon_url to chat_groups + owner-only set-icon RPC
-- Run in Supabase SQL editor (after groups tables exist).
-- =========================================================

-- Ensure base group tables exist (safe if already created)
create table if not exists public.chat_groups (
  id uuid primary key default gen_random_uuid(),
  name text not null check (char_length(btrim(name)) between 1 and 64),
  owner_id uuid not null,
  created_at timestamptz not null default now()
);

create table if not exists public.chat_group_members (
  group_id uuid not null references public.chat_groups(id) on delete cascade,
  user_id uuid not null,
  added_at timestamptz not null default now(),
  primary key (group_id, user_id)
);

alter table public.chat_groups
  add column if not exists icon_url text;

-- Basic length guard (null = no custom icon)
do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conrelid = 'public.chat_groups'::regclass
      and conname = 'chat_groups_icon_url_len'
  ) then
    alter table public.chat_groups
      add constraint chat_groups_icon_url_len
      check (icon_url is null or char_length(icon_url) between 1 and 500);
  end if;
end $$;

alter table public.chat_groups enable row level security;
alter table public.chat_group_members enable row level security;

-- Members can read groups they belong to; anyone authenticated can read rows
-- they can already see via membership policies (keep permissive read for app)
drop policy if exists "read groups" on public.chat_groups;
create policy "read groups" on public.chat_groups
  for select to authenticated
  using (
    exists (
      select 1 from public.chat_group_members m
      where m.group_id = id and m.user_id = auth.uid()
    )
    or owner_id = auth.uid()
    or public.chat_is_admin()
  );

drop policy if exists "read group members" on public.chat_group_members;
create policy "read group members" on public.chat_group_members
  for select to authenticated
  using (
    exists (
      select 1 from public.chat_group_members m
      where m.group_id = chat_group_members.group_id and m.user_id = auth.uid()
    )
    or public.chat_is_admin()
  );

-- Owner (or admin) sets / clears the group icon
create or replace function public.chat_group_set_icon(p_group uuid, p_icon text default null)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v text;
begin
  if auth.uid() is null then
    raise exception 'Not signed in';
  end if;

  if not exists (
    select 1 from public.chat_groups g
    where g.id = p_group
      and (g.owner_id = auth.uid() or public.chat_is_admin())
  ) then
    raise exception 'Only the group owner can change the icon';
  end if;

  v := nullif(btrim(coalesce(p_icon, '')), '');
  if v is not null then
    if char_length(v) > 500 then
      raise exception 'Icon URL is too long';
    end if;
    if v !~* '^https?://' then
      raise exception 'Icon must be an http(s) URL';
    end if;
  end if;

  update public.chat_groups
  set icon_url = v
  where id = p_group;

  return true;
end $$;

revoke execute on function public.chat_group_set_icon(uuid, text) from public, anon;
grant execute on function public.chat_group_set_icon(uuid, text) to authenticated;

do $$ begin
  alter publication supabase_realtime add table public.chat_groups;
exception when duplicate_object then null;
end $$;
do $$ begin
  alter publication supabase_realtime add table public.chat_group_members;
exception when duplicate_object then null;
end $$;

notify pgrst, 'reload schema';

-- Refresh API schema cache
notify pgrst, 'reload schema';
