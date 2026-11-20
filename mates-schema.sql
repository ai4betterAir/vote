-- MATES committee extension for OpenPoll.
-- Execute after schema.sql in the Supabase SQL Editor.
-- Member PINs must be loaded separately using the PRIVATE setup file, never committed to GitHub.
create extension if not exists pgcrypto;
create table if not exists public.mates_members(
 id uuid primary key default gen_random_uuid(),
 first_name text not null unique,
 pin_hash text not null,
 failed_attempts int not null default 0,
 locked_until timestamptz
);
create table if not exists public.mates_elections(
 id uuid primary key default gen_random_uuid(),
 title text not null,
 starts_at timestamptz not null,
 ends_at timestamptz not null,
 created_by uuid references auth.users(id),
 created_at timestamptz not null default now(),
 check(ends_at>starts_at)
);
create table if not exists public.mates_sessions(
 token_hash text primary key,
 election_id uuid not null references public.mates_elections(id) on delete cascade,
 member_id uuid not null references public.mates_members(id),
 expires_at timestamptz not null
);
create table if not exists public.mates_ballots(
 election_id uuid not null references public.mates_elections(id),
 member_id uuid not null references public.mates_members(id),
 position text not null check(position in ('President','Secretary','Vice President','Joint Secretary','Treasurer')),
 candidate_id uuid not null references public.mates_members(id),
 created_at timestamptz not null default now(),
 primary key(election_id,member_id,position),
 check(member_id<>candidate_id)
);
create index if not exists mates_ballot_count_idx on public.mates_ballots(election_id,position,candidate_id);
create index if not exists mates_session_expire_idx on public.mates_sessions(expires_at);

alter table public.mates_members enable row level security;
alter table public.mates_elections enable row level security;
alter table public.mates_sessions enable row level security;
alter table public.mates_ballots enable row level security;

revoke all on public.mates_members,public.mates_elections,public.mates_sessions,public.mates_ballots from anon,authenticated;
grant select on public.mates_elections to anon,authenticated;
drop policy if exists mates_elections_public on public.mates_elections;
create policy mates_elections_public on public.mates_elections for select to anon,authenticated using(true);

create or replace function public.mates_member_names()
returns table(id uuid,first_name text) language sql stable security definer set search_path=public,extensions,pg_temp as $$
 select m.id,m.first_name from public.mates_members m order by m.first_name;
$$;

create or replace function public.mates_create_election(p_title text,p_starts timestamptz,p_ends timestamptz)
returns uuid language plpgsql security definer set search_path=public,extensions,pg_temp as $$
declare e uuid;
begin
 if auth.uid() is null or not exists(select 1 from public.poll_admins where user_id=auth.uid()) then
  raise exception 'Only authorised administrators can create committee elections';
 end if;
 if char_length(btrim(coalesce(p_title,''))) not between 3 and 120
    or p_starts is null or p_ends is null or p_ends<=p_starts or p_ends<=now() then
  raise exception 'Invalid election title or times'; end if;
 if (select count(*) from public.mates_members)<>9 then raise exception 'Load all nine members first'; end if;
 insert into public.mates_elections(title,starts_at,ends_at,created_by)
 values(btrim(p_title),p_starts,p_ends,auth.uid()) returning id into e;
 return e;
end; $$;

-- Returns an ephemeral token, not the phone PIN. Maximum 5 failed attempts
-- per member during a one-hour lock window.
create or replace function public.mates_verify_member(p_election uuid,p_member uuid,p_last4 text)
returns text language plpgsql volatile security definer set search_path=public,extensions,pg_temp as $$
declare m public.mates_members%rowtype; tok text;
begin
 if not exists(select 1 from public.mates_elections where id=p_election
    and starts_at<=now() and ends_at>now()) then return null; end if;
 select * into m from public.mates_members where id=p_member for update;
 if not found or (m.locked_until is not null and m.locked_until>now()) then return null; end if;
 if p_last4 is null or p_last4 !~ '^[0-9]{4}$'
    or crypt(p_last4,m.pin_hash)<>m.pin_hash then
   update public.mates_members set failed_attempts=case
     when locked_until is not null and locked_until<=now() then 1
     else failed_attempts+1 end,
     locked_until=case
       when (case when locked_until is not null and locked_until<=now() then 1 else failed_attempts+1 end)>=5
       then now()+interval '1 hour' else null end
   where id=p_member;
   return null;
 end if;
 update public.mates_members set failed_attempts=0,locked_until=null where id=p_member;
 tok:=encode(gen_random_bytes(32),'hex');
 insert into public.mates_sessions(token_hash,election_id,member_id,expires_at)
 values(encode(digest(tok,'sha256'),'hex'),p_election,p_member,least(now()+interval '20 minutes',
 (select ends_at from public.mates_elections where id=p_election)));
 return tok;
end; $$;

create or replace function public.mates_ballot_status(p_election uuid,p_token text)
returns boolean language plpgsql stable security definer set search_path=public,extensions,pg_temp as $$
declare mid uuid;
begin
 select s.member_id into mid from public.mates_sessions s
 where s.election_id=p_election and s.token_hash=encode(digest(coalesce(p_token,''),'sha256'),'hex')
 and s.expires_at>now();
 if mid is null then raise exception 'Verification expired. Please verify again'; end if;
 return exists(select 1 from public.mates_ballots where election_id=p_election and member_id=mid);
end; $$;

create or replace function public.mates_submit_ballot(p_election uuid,p_token text,p_votes jsonb)
returns void language plpgsql volatile security definer set search_path=public,extensions,pg_temp as $$
declare mid uuid; rec jsonb;
begin
 perform 1 from public.mates_elections where id=p_election and starts_at<=now()
 and ends_at>now() for share;
 if not found then raise exception 'Election is not open'; end if;
 select s.member_id into mid from public.mates_sessions s
 where s.election_id=p_election and s.token_hash=encode(digest(coalesce(p_token,''),'sha256'),'hex')
 and s.expires_at>now() for update;
 if mid is null then raise exception 'Verification expired. Verify your name and phone digits again'; end if;
 if jsonb_typeof(p_votes) is distinct from 'array' or jsonb_array_length(p_votes)<>5 then
  raise exception 'Select a candidate for all five positions'; end if;
 if (select count(distinct v->>'position') from jsonb_array_elements(p_votes) v)<>5 then
  raise exception 'Each position must appear exactly once'; end if;
 if exists(select 1 from public.mates_ballots where election_id=p_election and member_id=mid) then
  raise exception 'Your ballot has already been submitted'; end if;
 for rec in select value from jsonb_array_elements(p_votes) loop
  if rec->>'position' not in ('President','Secretary','Vice President','Joint Secretary','Treasurer')
    or not exists(select 1 from public.mates_members c where c.id::text=rec->>'candidate_id')
    or rec->>'candidate_id'=mid::text then
    raise exception 'Invalid selection or self-vote'; end if;
  insert into public.mates_ballots(election_id,member_id,position,candidate_id)
  values(p_election,mid,rec->>'position',(rec->>'candidate_id')::uuid);
 end loop;
 delete from public.mates_sessions where token_hash=encode(digest(p_token,'sha256'),'hex');
end; $$;

create or replace function public.mates_results(p_election uuid)
returns table(position text,candidate_id uuid,votes bigint)
language plpgsql stable security definer set search_path=public,extensions,pg_temp as $$
begin
 if not exists(select 1 from public.mates_elections where id=p_election and ends_at<=now()) then
  raise exception 'Results are unavailable until voting closes'; end if;
 return query
 select p.pos,m.id,count(b.candidate_id)::bigint
 from unnest(array['President','Secretary','Vice President','Joint Secretary','Treasurer']) p(pos)
 cross join public.mates_members m
 left join public.mates_ballots b on b.election_id=p_election
 and b.position=p.pos and b.candidate_id=m.id
 group by p.pos,m.id;
end; $$;

revoke all on function public.mates_member_names() from public,anon,authenticated;
revoke all on function public.mates_create_election(text,timestamptz,timestamptz) from public,anon,authenticated;
revoke all on function public.mates_verify_member(uuid,uuid,text) from public,anon,authenticated;
revoke all on function public.mates_ballot_status(uuid,text) from public,anon,authenticated;
revoke all on function public.mates_submit_ballot(uuid,text,jsonb) from public,anon,authenticated;
revoke all on function public.mates_results(uuid) from public,anon,authenticated;
grant execute on function public.mates_member_names() to anon,authenticated;
grant execute on function public.mates_create_election(text,timestamptz,timestamptz) to authenticated;
grant execute on function public.mates_verify_member(uuid,uuid,text) to anon,authenticated;
grant execute on function public.mates_ballot_status(uuid,text) to anon,authenticated;
grant execute on function public.mates_submit_ballot(uuid,text,jsonb) to anon,authenticated;
grant execute on function public.mates_results(uuid) to anon,authenticated;

-- MATES administrator access: Masrur is the designated administrator.
-- Admin verification is separate from member ballot verification, and uses
-- the existing PRIVATE hashed phone suffix in mates_members.
create table if not exists public.mates_admin_sessions(
 token_hash text primary key,
 member_id uuid not null references public.mates_members(id),
 expires_at timestamptz not null
);
alter table public.mates_admin_sessions enable row level security;
revoke all on public.mates_admin_sessions from anon,authenticated;

create or replace function public.mates_admin_verify(p_last4 text)
returns text language plpgsql volatile security definer set search_path=public,extensions,pg_temp as $$
declare m public.mates_members%rowtype; tok text;
begin
 select * into m from public.mates_members where first_name='Masrur' for update;
 if not found or (m.locked_until is not null and m.locked_until>now()) then return null; end if;
 if p_last4 is null or p_last4 !~ '^[0-9]{4}$'
    or crypt(p_last4,m.pin_hash)<>m.pin_hash then
   update public.mates_members set
   failed_attempts=case when locked_until is not null and locked_until<=now() then 1 else failed_attempts+1 end,
   locked_until=case when
     (case when locked_until is not null and locked_until<=now() then 1 else failed_attempts+1 end)>=5
     then now()+interval '1 hour' else null end
   where id=m.id;
   return null;
 end if;
 update public.mates_members set failed_attempts=0,locked_until=null where id=m.id;
 tok:=encode(gen_random_bytes(32),'hex');
 insert into public.mates_admin_sessions(token_hash,member_id,expires_at)
 values(encode(digest(tok,'sha256'),'hex'),m.id,now()+interval '20 minutes');
 return tok;
end; $$;

create or replace function public.mates_create_election_admin(
 p_token text,p_title text,p_starts timestamptz,p_ends timestamptz
) returns uuid language plpgsql volatile security definer set search_path=public,extensions,pg_temp as $$
declare new_id uuid;
begin
 if not exists(
   select 1 from public.mates_admin_sessions s
   join public.mates_members m on m.id=s.member_id
   where s.token_hash=encode(digest(coalesce(p_token,''),'sha256'),'hex')
     and s.expires_at>now() and m.first_name='Masrur'
 ) then raise exception 'Administrator verification expired. Verify again'; end if;
 if char_length(btrim(coalesce(p_title,''))) not between 3 and 120
    or p_starts is null or p_ends is null or p_ends<=p_starts or p_ends<=now()
 then raise exception 'Invalid election title or dates'; end if;
 if (select count(*) from public.mates_members)<>9 then
   raise exception 'Load the nine members before creating an election'; end if;
 insert into public.mates_elections(title,starts_at,ends_at)
 values(btrim(p_title),p_starts,p_ends) returning id into new_id;
 return new_id;
end; $$;

create or replace function public.mates_admin_sign_out(p_token text)
returns void language plpgsql volatile security definer set search_path=public,extensions,pg_temp as $$
begin
 delete from public.mates_admin_sessions
 where token_hash=encode(digest(coalesce(p_token,''),'sha256'),'hex');
end; $$;

-- Remove the former email-admin path for this specific committee election.
-- Other OpenPoll poll administration remains unchanged.
revoke execute on function public.mates_create_election(text,timestamptz,timestamptz) from authenticated;
revoke all on function public.mates_admin_verify(text) from public,anon,authenticated;
revoke all on function public.mates_create_election_admin(text,text,timestamptz,timestamptz) from public,anon,authenticated;
revoke all on function public.mates_admin_sign_out(text) from public,anon,authenticated;
grant execute on function public.mates_admin_verify(text) to anon,authenticated;
grant execute on function public.mates_create_election_admin(text,text,timestamptz,timestamptz) to anon,authenticated;
grant execute on function public.mates_admin_sign_out(text) to anon,authenticated;
