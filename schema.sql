-- CommitteeVote database — execute once in Supabase SQL Editor.
-- Configure Authentication > URL Configuration with your GitHub Pages address.
create extension if not exists pgcrypto;

create table if not exists public.elections (
 id uuid primary key default gen_random_uuid(),
 title text not null check (char_length(title) between 3 and 120),
 description text not null default '',
 starts_at timestamptz not null,
 ends_at timestamptz not null,
 created_by uuid not null references auth.users(id),
 created_at timestamptz not null default now(),
 constraint valid_window check (ends_at > starts_at)
);
create table if not exists public.offices (
 id uuid primary key default gen_random_uuid(),
 election_id uuid not null references public.elections(id) on delete cascade,
 title text not null,
 sort_order int not null,
 unique(election_id,id),
 unique(election_id,title),
 unique(election_id,sort_order)
);
create table if not exists public.candidates (
 id uuid primary key default gen_random_uuid(),
 election_id uuid not null references public.elections(id) on delete cascade,
 name text not null,
 sort_order int not null,
 unique(election_id,id),
 unique(election_id,name),
 unique(election_id,sort_order)
);
create table if not exists public.election_admins (
 user_id uuid primary key references auth.users(id) on delete cascade
);
-- Only emails added here can vote; keep this table private.
create table if not exists public.voter_allowlist (
 email text primary key check (email = lower(btrim(email)) and position('@' in email)>1)
);
create table if not exists public.votes (
 id uuid primary key default gen_random_uuid(),
 election_id uuid not null references public.elections(id),
 office_id uuid not null,
 candidate_id uuid not null,
 voter_id uuid not null references auth.users(id),
 created_at timestamptz not null default now(),
 foreign key(election_id,office_id) references public.offices(election_id,id),
 foreign key(election_id,candidate_id) references public.candidates(election_id,id),
 unique(election_id,office_id,voter_id)
);
create index if not exists votes_election_office_candidate on public.votes(election_id,office_id,candidate_id);

alter table public.elections enable row level security;
alter table public.offices enable row level security;
alter table public.candidates enable row level security;
alter table public.election_admins enable row level security;
alter table public.voter_allowlist enable row level security;
alter table public.votes enable row level security;

-- Public may read only election metadata; no direct vote, allowlist or administrator modifications.
drop policy if exists elections_public_read on public.elections;
create policy elections_public_read on public.elections for select to anon,authenticated using(true);
drop policy if exists offices_public_read on public.offices;
create policy offices_public_read on public.offices for select to anon,authenticated using(true);
drop policy if exists candidates_public_read on public.candidates;
create policy candidates_public_read on public.candidates for select to anon,authenticated using(true);
drop policy if exists admins_self_read on public.election_admins;
create policy admins_self_read on public.election_admins for select to authenticated using(user_id=(select auth.uid()));

revoke all on public.elections,public.offices,public.candidates,public.election_admins,public.voter_allowlist,public.votes from anon,authenticated;
grant select on public.elections,public.offices,public.candidates to anon,authenticated;
grant select on public.election_admins to authenticated;

-- Administrator-only poll creation. Runs atomically and uses a shared nominee list.
create or replace function public.create_election(
 p_title text, p_description text, p_starts timestamptz, p_ends timestamptz,
 p_offices text[], p_candidates text[]
) returns uuid language plpgsql security definer set search_path = public,pg_temp as $$
declare eid uuid; item text; i int;
begin
 if auth.uid() is null or not exists(select 1 from public.election_admins where user_id=auth.uid()) then
   raise exception 'Not authorised to create elections';
 end if;
 if char_length(btrim(p_title)) not between 3 and 120
    or p_ends<=p_starts or p_ends<=now()
    or coalesce(array_length(p_offices,1),0) not between 1 and 20
    or coalesce(array_length(p_candidates,1),0) not between 2 and 40 then
   raise exception 'Invalid election settings';
 end if;
 if exists(select 1 from unnest(p_offices) t where btrim(t)='' or t is null or char_length(t)>100)
    or exists(select 1 from unnest(p_candidates) t where btrim(t)='' or t is null or char_length(t)>100) then
   raise exception 'Names must be between 1 and 100 characters';
 end if;
 if (select count(distinct lower(btrim(t))) from unnest(p_offices) t)<>array_length(p_offices,1)
    or (select count(distinct lower(btrim(t))) from unnest(p_candidates) t)<>array_length(p_candidates,1) then
   raise exception 'Duplicate names are not permitted';
 end if;
 insert into public.elections(title,description,starts_at,ends_at,created_by)
 values(btrim(p_title),left(coalesce(p_description,''),500),p_starts,p_ends,auth.uid())
 returning id into eid;
 for i in 1..array_length(p_offices,1) loop
   insert into public.offices(election_id,title,sort_order) values(eid,btrim(p_offices[i]),i);
 end loop;
 for i in 1..array_length(p_candidates,1) loop
   insert into public.candidates(election_id,name,sort_order) values(eid,btrim(p_candidates[i]),i);
 end loop;
 return eid;
end; $$;

-- A verified voter submits a complete ballot in a single transaction.
-- Security enforced using server-side current time; not the browser clock.
create or replace function public.submit_election_ballot(p_election uuid,p_choices jsonb)
returns void language plpgsql security definer set search_path=public,pg_temp as $$
declare voter uuid; total_offices int; provided int;
begin
 voter:=auth.uid();
 if voter is null then raise exception 'Sign in before voting'; end if;
 if not exists(select 1 from public.voter_allowlist where email=lower(coalesce(auth.jwt()->>'email',''))) then
   raise exception 'Your email is not on the approved voter list';
 end if;
 -- Row locking serialises submission against edits (there are no poll edit APIs).
 perform 1 from public.elections where id=p_election and starts_at<=now() and ends_at>now() for share;
 if not found then raise exception 'Voting is not open'; end if;
 if jsonb_typeof(p_choices) is distinct from 'array' then raise exception 'Invalid ballot'; end if;
 select count(*) into total_offices from public.offices where election_id=p_election;
 select count(*) into provided from jsonb_array_elements(p_choices);
 if provided<>total_offices or provided=0 then raise exception 'Vote once for every position'; end if;
 if exists(
  select 1 from jsonb_array_elements(p_choices) c
  where jsonb_typeof(c) <> 'object'
     or not exists(select 1 from public.offices o
        where o.election_id=p_election and o.id::text=c->>'office_id')
     or not exists(select 1 from public.candidates k
        where k.election_id=p_election and k.id::text=c->>'candidate_id')
 ) then raise exception 'Invalid candidate or position'; end if;
 if (select count(distinct c->>'office_id') from jsonb_array_elements(p_choices) c)<>total_offices then
   raise exception 'Each position must appear exactly once'; end if;
 if exists(select 1 from public.votes where election_id=p_election and voter_id=voter) then
   raise exception 'You have already voted in this election'; end if;
 insert into public.votes(election_id,office_id,candidate_id,voter_id)
 select p_election,(c->>'office_id')::uuid,(c->>'candidate_id')::uuid,voter
 from jsonb_array_elements(p_choices) c;
end; $$;

-- Only the current voter can learn whether they have already voted.
-- No vote choices are exposed.
create or replace function public.my_election_votes(p_election uuid)
returns table(office_id uuid) language sql stable security definer set search_path=public,pg_temp as $$
 select distinct v.office_id from public.votes v
 where v.election_id=p_election and v.voter_id=auth.uid();
$$;

-- Results are inaccessible to the public and authenticated clients until closing.
-- Includes zero-vote candidates, for every office.
create or replace function public.election_results(p_election uuid)
returns table(office_id uuid,candidate_id uuid,votes bigint)
language plpgsql stable security definer set search_path=public,pg_temp as $$
begin
 if not exists(select 1 from public.elections e where e.id=p_election and e.ends_at<=now()) then
   raise exception 'Results are available only after the election closes';
 end if;
 return query
 select o.id,k.id,count(v.id)::bigint
 from public.offices o
 join public.candidates k on k.election_id=o.election_id
 left join public.votes v on v.election_id=o.election_id and v.office_id=o.id and v.candidate_id=k.id
 where o.election_id=p_election
 group by o.id,k.id;
end; $$;

revoke all on function public.create_election(text,text,timestamptz,timestamptz,text[],text[]) from public,anon,authenticated;
revoke all on function public.submit_election_ballot(uuid,jsonb) from public,anon,authenticated;
revoke all on function public.my_election_votes(uuid) from public,anon,authenticated;
revoke all on function public.election_results(uuid) from public,anon,authenticated;
grant execute on function public.create_election(text,text,timestamptz,timestamptz,text[],text[]) to authenticated;
grant execute on function public.submit_election_ballot(uuid,jsonb) to authenticated;
grant execute on function public.my_election_votes(uuid) to authenticated;
grant execute on function public.election_results(uuid) to anon,authenticated;

-- After your first Supabase email sign-in, designate the administrator:
-- insert into public.election_admins(user_id)
-- select id from auth.users where email='YOUR_ADMIN_EMAIL@example.com'
-- on conflict do nothing;
-- Add voting members:
-- insert into public.voter_allowlist(email) values
-- ('member1@example.com'),('member2@example.com')
-- on conflict do nothing;
