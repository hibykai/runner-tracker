-- Coast to Coast Run — initial multiplayer schema
--
-- Apply this to a fresh Supabase project.
--   1. Create a project at https://supabase.com
--   2. Authentication → Sign In / Up → enable "Anonymous Sign-Ins"
--   3. SQL Editor → New query → paste this entire file → Run
--   4. Copy the project URL + anon key (Settings → API) into index.html
--      (constants SUPABASE_URL and SUPABASE_ANON_KEY)
--
-- Identity model: anonymous Supabase auth. Every browser gets a stable
-- auth.uid() persisted in localStorage by the supabase-js client.
--
-- Authorization model: RLS gates every row on "auth.uid() is an active
-- member of this lobby_id." Strangers can't write to lobby_members
-- directly — the join_lobby RPC (SECURITY DEFINER) is the only gate.

create extension if not exists pgcrypto;

-- =========================================================================
-- Tables
-- =========================================================================

create table lobbies (
  id              uuid primary key default gen_random_uuid(),
  code            text unique not null,                    -- 6-char A-Z0-9
  name            text not null,
  admin_user_id   uuid not null references auth.users(id),
  is_private      boolean not null default true,
  status          text not null default 'active'
                    check (status in ('active','ended')),
  finish_miles    integer not null default 2790,
  created_at      timestamptz not null default now()
);

create table lobby_members (
  lobby_id        uuid not null references lobbies(id) on delete cascade,
  user_id         uuid not null references auth.users(id),
  role            text not null default 'member'
                    check (role in ('admin','member')),
  status          text not null default 'active'
                    check (status in ('active','kicked')),
  name            text not null,
  skin            text not null,
  shirt           text not null,
  shorts          text not null,
  hat             text not null,
  first_finish    timestamptz,
  last_seen       timestamptz not null default now(),
  joined_at       timestamptz not null default now(),
  primary key (lobby_id, user_id)
);

create table logs (
  id              uuid primary key default gen_random_uuid(),
  lobby_id        uuid not null references lobbies(id) on delete cascade,
  user_id         uuid not null references auth.users(id),
  date            date not null,
  miles           numeric(7,2) not null check (miles > 0),
  created_at      timestamptz not null default now()
);
create index logs_lobby_user_idx    on logs (lobby_id, user_id);
create index logs_lobby_created_idx on logs (lobby_id, created_at desc);

create table recovery_codes (
  passphrase_hash text primary key,
  user_id         uuid not null references auth.users(id),
  lobby_id        uuid not null references lobbies(id) on delete cascade,
  created_at      timestamptz not null default now()
);
create index recovery_codes_user_idx on recovery_codes (user_id);

-- =========================================================================
-- Helper functions
-- =========================================================================

-- Predicate used by every RLS policy.
create or replace function is_active_member(p_lobby_id uuid)
returns boolean
language sql stable security definer
as $$
  select exists (
    select 1 from lobby_members
    where lobby_id = p_lobby_id
      and user_id  = auth.uid()
      and status   = 'active'
  )
$$;

-- Random 6-char code, A-Z + 2-9 (ambiguous I/O/0/1 omitted).
create or replace function gen_lobby_code()
returns text language plpgsql as $$
declare
  alphabet text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  result   text := '';
  i        int;
begin
  for i in 1..6 loop
    result := result || substr(alphabet, 1 + floor(random() * length(alphabet))::int, 1);
  end loop;
  return result;
end; $$;

-- One-way hash of a recovery passphrase. We never store the plaintext.
create or replace function hash_passphrase(p text)
returns text language sql immutable
as $$ select encode(digest(p, 'sha256'), 'hex') $$;

-- =========================================================================
-- Row-Level Security
-- =========================================================================

alter table lobbies         enable row level security;
alter table lobby_members   enable row level security;
alter table logs            enable row level security;
alter table recovery_codes  enable row level security;

-- LOBBIES: members can read their own lobby. Inserts/updates go through RPCs.
create policy lobbies_select_member on lobbies
  for select using (is_active_member(id));

-- LOBBY_MEMBERS: members can read all rows in their lobby; can update only
-- their own row's avatar/name fields. Inserts and the kick mutation go
-- through SECURITY DEFINER RPCs.
create policy lobby_members_select_member on lobby_members
  for select using (is_active_member(lobby_id));

create policy lobby_members_update_self on lobby_members
  for update using (user_id = auth.uid() and is_active_member(lobby_id))
  with check     (user_id = auth.uid());

-- LOGS: members read all logs in their lobby; can write only their own.
create policy logs_select_member on logs
  for select using (is_active_member(lobby_id));

create policy logs_insert_self on logs
  for insert with check (user_id = auth.uid() and is_active_member(lobby_id));

create policy logs_update_self on logs
  for update using (user_id = auth.uid() and is_active_member(lobby_id))
  with check     (user_id = auth.uid());

create policy logs_delete_self on logs
  for delete using (user_id = auth.uid() and is_active_member(lobby_id));

-- RECOVERY_CODES: no client access. Only create_lobby/redeem_recovery_code
-- (SECURITY DEFINER) touch this table.

-- =========================================================================
-- Finish-line trigger
-- =========================================================================

-- When a log insert pushes the member's cumulative miles past finish_miles
-- for the first time, stamp first_finish = now() atomically.
-- This eliminates the simultaneous-claim race (Postgres serializes writes).
create or replace function set_first_finish_on_log()
returns trigger language plpgsql security definer
as $$
declare
  v_total   numeric;
  v_finish  int;
  v_already timestamptz;
begin
  select first_finish into v_already
    from lobby_members
    where lobby_id = NEW.lobby_id and user_id = NEW.user_id;
  if v_already is not null then return NEW; end if;

  select coalesce(sum(miles), 0) into v_total
    from logs
    where lobby_id = NEW.lobby_id and user_id = NEW.user_id;

  select finish_miles into v_finish
    from lobbies where id = NEW.lobby_id;

  if v_total >= v_finish then
    update lobby_members set first_finish = now()
      where lobby_id = NEW.lobby_id
        and user_id  = NEW.user_id
        and first_finish is null;
  end if;

  return NEW;
end; $$;

create trigger logs_finish_trigger
  after insert on logs
  for each row execute function set_first_finish_on_log();

-- =========================================================================
-- RPCs
-- =========================================================================

-- Create a lobby; caller becomes the admin and first member.
-- The 4-word passphrase is generated client-side; we hash it and stash
-- in recovery_codes so the admin can recover this role from another
-- browser via redeem_recovery_code.
create or replace function create_lobby(
  p_name         text,
  p_is_private   boolean,
  p_member_name  text,
  p_skin text, p_shirt text, p_shorts text, p_hat text,
  p_passphrase   text
) returns table (lobby_id uuid, code text)
language plpgsql security definer
as $$
declare
  v_uid     uuid := auth.uid();
  v_lobby   uuid;
  v_code    text;
  v_attempt int := 0;
begin
  if v_uid is null              then raise exception 'Not authenticated'; end if;
  if length(coalesce(p_name,'')) = 0 then raise exception 'Lobby name required'; end if;
  if length(coalesce(p_passphrase,'')) < 8 then raise exception 'Passphrase required'; end if;

  loop
    v_code := gen_lobby_code();
    begin
      insert into lobbies (code, name, admin_user_id, is_private)
        values (v_code, p_name, v_uid, coalesce(p_is_private, true))
        returning id into v_lobby;
      exit;
    exception when unique_violation then
      v_attempt := v_attempt + 1;
      if v_attempt > 5 then raise; end if;
    end;
  end loop;

  insert into lobby_members (lobby_id, user_id, role, name, skin, shirt, shorts, hat)
    values (v_lobby, v_uid, 'admin', p_member_name, p_skin, p_shirt, p_shorts, p_hat);

  insert into recovery_codes (passphrase_hash, user_id, lobby_id)
    values (hash_passphrase(p_passphrase), v_uid, v_lobby);

  return query select v_lobby, v_code;
end; $$;

-- Join a lobby with its code. This is the ONLY way a non-member's row
-- lands in lobby_members — direct INSERT is blocked by RLS.
create or replace function join_lobby(
  p_code text, p_member_name text,
  p_skin text, p_shirt text, p_shorts text, p_hat text
) returns uuid
language plpgsql security definer
as $$
declare
  v_uid             uuid := auth.uid();
  v_lobby           uuid;
  v_existing_status text;
begin
  if v_uid is null then raise exception 'Not authenticated'; end if;

  select id into v_lobby from lobbies where code = upper(p_code);
  if v_lobby is null then raise exception 'Lobby not found'; end if;

  select status into v_existing_status
    from lobby_members where lobby_id = v_lobby and user_id = v_uid;

  if v_existing_status = 'kicked' then
    raise exception 'You have been removed from this lobby';
  end if;

  if v_existing_status = 'active' then
    update lobby_members
      set name = p_member_name, skin = p_skin, shirt = p_shirt,
          shorts = p_shorts, hat = p_hat, last_seen = now()
      where lobby_id = v_lobby and user_id = v_uid;
    return v_lobby;
  end if;

  insert into lobby_members (lobby_id, user_id, role, name, skin, shirt, shorts, hat)
    values (v_lobby, v_uid, 'member', p_member_name, p_skin, p_shirt, p_shorts, p_hat);

  return v_lobby;
end; $$;

-- Re-bind the admin role to the calling browser's identity, using the
-- one-time recovery passphrase. Migrates the original admin's
-- lobby_members + logs rows to the caller's auth.uid().
create or replace function redeem_recovery_code(p_passphrase text)
returns uuid
language plpgsql security definer
as $$
declare
  v_uid     uuid := auth.uid();
  v_old_uid uuid;
  v_lobby   uuid;
begin
  if v_uid is null then raise exception 'Not authenticated'; end if;

  select user_id, lobby_id into v_old_uid, v_lobby
    from recovery_codes
    where passphrase_hash = hash_passphrase(p_passphrase);

  if v_old_uid is null then raise exception 'Invalid passphrase'; end if;

  if v_old_uid = v_uid then
    delete from recovery_codes where passphrase_hash = hash_passphrase(p_passphrase);
    return v_lobby;
  end if;

  -- If the caller already has data in this lobby, drop it first.
  delete from lobby_members where lobby_id = v_lobby and user_id = v_uid;
  delete from logs           where lobby_id = v_lobby and user_id = v_uid;

  update lobby_members set user_id = v_uid
    where lobby_id = v_lobby and user_id = v_old_uid;
  update logs set user_id = v_uid
    where lobby_id = v_lobby and user_id = v_old_uid;
  update lobbies set admin_user_id = v_uid
    where id = v_lobby and admin_user_id = v_old_uid;

  delete from recovery_codes where passphrase_hash = hash_passphrase(p_passphrase);
  return v_lobby;
end; $$;

-- Admin: kick a member (sets status='kicked'; row is preserved for audit).
create or replace function kick_member(p_lobby_id uuid, p_target_user_id uuid)
returns void language plpgsql security definer
as $$
declare v_uid uuid := auth.uid();
begin
  if v_uid is null then raise exception 'Not authenticated'; end if;
  if not exists (select 1 from lobbies where id = p_lobby_id and admin_user_id = v_uid) then
    raise exception 'Only the admin can kick members';
  end if;
  if p_target_user_id = v_uid then raise exception 'Cannot kick yourself'; end if;
  update lobby_members set status = 'kicked'
    where lobby_id = p_lobby_id and user_id = p_target_user_id;
end; $$;

-- Admin: flip is_private.
create or replace function toggle_private(p_lobby_id uuid)
returns boolean language plpgsql security definer
as $$
declare v_uid uuid := auth.uid(); v_new boolean;
begin
  if not exists (select 1 from lobbies where id = p_lobby_id and admin_user_id = v_uid) then
    raise exception 'Only the admin can change this';
  end if;
  update lobbies set is_private = not is_private
    where id = p_lobby_id returning is_private into v_new;
  return v_new;
end; $$;

-- Admin: regenerate the join code (old links stop working).
create or replace function regenerate_code(p_lobby_id uuid)
returns text language plpgsql security definer
as $$
declare v_uid uuid := auth.uid(); v_code text; v_attempt int := 0;
begin
  if not exists (select 1 from lobbies where id = p_lobby_id and admin_user_id = v_uid) then
    raise exception 'Only the admin can regenerate the code';
  end if;
  loop
    v_code := gen_lobby_code();
    begin
      update lobbies set code = v_code where id = p_lobby_id;
      exit;
    exception when unique_violation then
      v_attempt := v_attempt + 1;
      if v_attempt > 5 then raise; end if;
    end;
  end loop;
  return v_code;
end; $$;

-- Admin: end the race (status='ended'). Renderers can show a "Finished" badge.
create or replace function end_race(p_lobby_id uuid)
returns void language plpgsql security definer
as $$
declare v_uid uuid := auth.uid();
begin
  if not exists (select 1 from lobbies where id = p_lobby_id and admin_user_id = v_uid) then
    raise exception 'Only the admin can end the race';
  end if;
  update lobbies set status = 'ended' where id = p_lobby_id;
end; $$;

-- Admin: hand off the admin role to another active member.
create or replace function transfer_admin(p_lobby_id uuid, p_target_user_id uuid)
returns void language plpgsql security definer
as $$
declare v_uid uuid := auth.uid();
begin
  if not exists (select 1 from lobbies where id = p_lobby_id and admin_user_id = v_uid) then
    raise exception 'Only the current admin can transfer';
  end if;
  if not exists (select 1 from lobby_members
                 where lobby_id = p_lobby_id and user_id = p_target_user_id and status = 'active') then
    raise exception 'Target must be an active member';
  end if;
  update lobbies        set admin_user_id = p_target_user_id where id = p_lobby_id;
  update lobby_members  set role = 'member' where lobby_id = p_lobby_id and user_id = v_uid;
  update lobby_members  set role = 'admin'  where lobby_id = p_lobby_id and user_id = p_target_user_id;
end; $$;

-- Any active member: claim admin if current admin has been stale 7+ days.
create or replace function claim_admin(p_lobby_id uuid)
returns void language plpgsql security definer
as $$
declare
  v_uid              uuid := auth.uid();
  v_admin_last_seen  timestamptz;
begin
  if v_uid is null then raise exception 'Not authenticated'; end if;
  if not exists (select 1 from lobby_members
                 where lobby_id = p_lobby_id and user_id = v_uid and status = 'active') then
    raise exception 'You must be an active member of this lobby';
  end if;
  select m.last_seen into v_admin_last_seen
    from lobby_members m
    join lobbies l on l.id = m.lobby_id
    where l.id = p_lobby_id and m.user_id = l.admin_user_id;
  if v_admin_last_seen is null or now() - v_admin_last_seen < interval '7 days' then
    raise exception 'Admin is not stale enough (must be 7+ days)';
  end if;
  update lobbies        set admin_user_id = v_uid where id = p_lobby_id;
  update lobby_members  set role = 'member'
    where lobby_id = p_lobby_id and role = 'admin' and user_id != v_uid;
  update lobby_members  set role = 'admin'
    where lobby_id = p_lobby_id and user_id = v_uid;
end; $$;

-- Heartbeat: any active member bumps their last_seen. Called every 30s
-- by the client so we can detect offline players.
create or replace function heartbeat(p_lobby_id uuid)
returns void language sql security definer
as $$
  update lobby_members
    set last_seen = now()
    where lobby_id = p_lobby_id and user_id = auth.uid() and status = 'active';
$$;

-- =========================================================================
-- Realtime — broadcast changes on the tables clients subscribe to.
-- =========================================================================

alter publication supabase_realtime add table lobby_members;
alter publication supabase_realtime add table logs;
