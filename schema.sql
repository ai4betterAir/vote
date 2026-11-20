-- OpenPoll schema: create flexible polls with independent answer options per question.
-- Run this SQL in a NEW Supabase project, or migrate an existing project carefully.
-- These tables use a poll_ prefix and do not overwrite the earlier election tables.
create extension if not exists pgcrypto;

create table if not exists public.poll_admins (
 user_id uuid primary key references auth.users(id) on delete cascade
);
create table if not exists public.poll_voters (
 email text primary key check(email=lower(btrim(email)) and position('@' in email)>1)
);
create table if not exists public.polls (
 id uuid primary key default gen_random_uuid(),
 title text not null check (char_length(title) between 3 and 120),
 description text not null default '',
 starts_at timestamptz not null,
 ends_at timestamptz not null,
 created_by uuid not null references auth.users(id),
 created_at timestamptz not null default now(),
 constraint poll_dates_valid check(ends_at>starts_at)
);
create table if not exists public.poll_questions (
 id uuid primary key default gen_random_uuid(),
 poll_id uuid not null references public.polls(id) on delete cascade,
 title text not null check(char_length(title) between 1 and 150),
 sort_order int not null,
 unique(poll_id,id),
 unique(poll_id,sort_order),
 unique(poll_id,title)
);
create table if not exists public.poll_options (
 id uuid primary key default gen_random_uuid(),
 poll_id uuid not null,
 question_id uuid not null,
 label text not null check(char_length(label) between 1 and 150),
 sort_order int not null,
 foreign key(poll_id,question_id) references public.poll_questions(poll_id,id) on delete cascade,
 unique(poll_id,question_id,id),
 unique(question_id,sort_order),
 unique(question_id,label)
);
create table if not exists public.poll_responses (
 id uuid primary key default gen_random_uuid(),
 poll_id uuid not null references public.polls(id),
 question_id uuid not null,
 option_id uuid not null,
 voter_id uuid not null references auth.users(id),
 created_at timestamptz not null default now(),
 foreign key(poll_id,question_id) references public.poll_questions(poll_id,id),
 foreign key(poll_id,question_id,option_id) references public.poll_options(poll_id,question_id,id),
 unique(poll_id,question_id,voter_id)
);
create index if not exists poll_responses_count_idx on public.poll_responses(poll_id,question_id,option_id);

alter table public.poll_admins enable row level security;
alter table public.poll_voters enable row level security;
alter table public.polls enable row level security;
alter table public.poll_questions enable row level security;
alter table public.poll_options enable row level security;
alter table public.poll_responses enable row level security;

drop policy if exists poll_admins_own_read on public.poll_admins;
create policy poll_admins_own_read on public.poll_admins for select to authenticated using(user_id=(select auth.uid()));
drop policy if exists polls_public_read on public.polls;
create policy polls_public_read on public.polls for select to anon,authenticated using(true);
drop policy if exists poll_questions_public_read on public.poll_questions;
create policy poll_questions_public_read on public.poll_questions for select to anon,authenticated using(true);
drop policy if exists poll_options_public_read on public.poll_options;
create policy poll_options_public_read on public.poll_options for select to anon,authenticated using(true);

revoke all on public.poll_admins,public.poll_voters,public.polls,public.poll_questions,public.poll_options,public.poll_responses from anon,authenticated;
grant select on public.poll_admins to authenticated;
grant select on public.polls,public.poll_questions,public.poll_options to anon,authenticated;

create or replace function public.create_poll(
 p_title text, p_description text, p_starts timestamptz, p_ends timestamptz, p_questions jsonb
) returns uuid language plpgsql security definer set search_path=public,pg_temp as $$
declare pid uuid; qid uuid; q jsonb; o jsonb; qi int=0; oi int;
begin
 if auth.uid() is null or not exists(select 1 from public.poll_admins where user_id=auth.uid()) then
  raise exception 'Only authorised poll administrators can create polls';
 end if;
 if char_length(btrim(coalesce(p_title,''))) not between 3 and 120
    or char_length(coalesce(p_description,''))>500
    or p_starts is null or p_ends is null or p_ends<=p_starts or p_ends<=now()
    or jsonb_typeof(p_questions) is distinct from 'array'
    or jsonb_array_length(p_questions) not between 1 and 25 then
   raise exception 'Invalid poll title, schedule or questions';
 end if;
 if exists(select 1 from jsonb_array_elements(p_questions) x
  where jsonb_typeof(x) <> 'object'
     or char_length(btrim(coalesce(x->>'title',''))) not between 1 and 150
     or jsonb_typeof(x->'options') is distinct from 'array'
 ) then raise exception 'Every question requires a title and array of answers'; end if;
 if (select count(distinct lower(btrim(q->>'title'))) from jsonb_array_elements(p_questions) q)<>jsonb_array_length(p_questions) then
   raise exception 'Question titles must be unique'; end if;
 for q in select value from jsonb_array_elements(p_questions) loop
  if jsonb_array_length(q->'options') not between 2 and 40 then
    raise exception 'Every question needs 2 to 40 answers';
  end if;
  if exists(select 1 from jsonb_array_elements(q->'options') a
   where jsonb_typeof(a)<>'string'
    or char_length(btrim(a#>>'{}')) not between 1 and 150) then
    raise exception 'Answer choices must be nonempty strings up to 150 characters';
  end if;
  if (select count(distinct lower(btrim(a#>>'{}'))) from jsonb_array_elements(q->'options') a)<>jsonb_array_length(q->'options') then
   raise exception 'Answer choices must be unique within each question';
  end if;
 end loop;
 insert into public.polls(title,description,starts_at,ends_at,created_by)
 values(btrim(p_title),coalesce(p_description,''),p_starts,p_ends,auth.uid())
 returning id into pid;
 for q in select value from jsonb_array_elements(p_questions) loop
  qi:=qi+1;oi:=0;
  insert into public.poll_questions(poll_id,title,sort_order)
  values(pid,btrim(q->>'title'),qi) returning id into qid;
  for o in select value from jsonb_array_elements(q->'options') loop
   oi:=oi+1;
   insert into public.poll_options(poll_id,question_id,label,sort_order)
   values(pid,qid,btrim(o#>>'{}'),oi);
  end loop;
 end loop;
 return pid;
end; $$;

create or replace function public.submit_poll_ballot(p_poll uuid,p_answers jsonb)
returns void language plpgsql security definer set search_path=public,pg_temp as $$
declare uid uuid; n int;
begin
 uid:=auth.uid();
 if uid is null then raise exception 'Sign in to vote'; end if;
 if not exists(select 1 from public.poll_voters where email=lower(coalesce(auth.jwt()->>'email',''))) then
  raise exception 'Your email is not on the approved voter list';
 end if;
 perform 1 from public.polls where id=p_poll and starts_at<=now() and ends_at>now() for share;
 if not found then raise exception 'Poll is not open'; end if;
 if jsonb_typeof(p_answers) is distinct from 'array' then raise exception 'Invalid ballot format'; end if;
 select count(*) into n from public.poll_questions where poll_id=p_poll;
 if jsonb_array_length(p_answers)<>n or n=0 then raise exception 'You must answer every question exactly once'; end if;
 if exists(select 1 from jsonb_array_elements(p_answers) x where jsonb_typeof(x)<>'object'
   or not exists(select 1 from public.poll_options o where o.poll_id=p_poll and o.question_id::text=x->>'question_id' and o.id::text=x->>'option_id')
 ) then raise exception 'Invalid question or answer'; end if;
 if (select count(distinct x->>'question_id') from jsonb_array_elements(p_answers) x)<>n then
  raise exception 'Duplicate question in ballot'; end if;
 if exists(select 1 from public.poll_responses where poll_id=p_poll and voter_id=uid) then
  raise exception 'You have already submitted this poll'; end if;
 insert into public.poll_responses(poll_id,question_id,option_id,voter_id)
 select p_poll,(x->>'question_id')::uuid,(x->>'option_id')::uuid,uid
 from jsonb_array_elements(p_answers) x;
end; $$;

-- Only reveals whether the current user has voted, never their selected options.
create or replace function public.my_poll_responses(p_poll uuid)
returns table(question_id uuid) language sql stable security definer set search_path=public,pg_temp as $$
 select distinct r.question_id from public.poll_responses r
 where r.poll_id=p_poll and r.voter_id=auth.uid();
$$;

-- Results are protected by the database server closing time, not client-side time.
create or replace function public.poll_results(p_poll uuid)
returns table(question_id uuid,option_id uuid,votes bigint)
language plpgsql stable security definer set search_path=public,pg_temp as $$
begin
 if not exists(select 1 from public.polls p where p.id=p_poll and p.ends_at<=now()) then
  raise exception 'Results are only available after the poll closes';
 end if;
 return query
 select o.question_id,o.id,count(r.id)::bigint
 from public.poll_options o
 left join public.poll_responses r on r.poll_id=o.poll_id and r.question_id=o.question_id and r.option_id=o.id
 where o.poll_id=p_poll
 group by o.question_id,o.id;
end; $$;

revoke all on function public.create_poll(text,text,timestamptz,timestamptz,jsonb) from public,anon,authenticated;
revoke all on function public.submit_poll_ballot(uuid,jsonb) from public,anon,authenticated;
revoke all on function public.my_poll_responses(uuid) from public,anon,authenticated;
revoke all on function public.poll_results(uuid) from public,anon,authenticated;
grant execute on function public.create_poll(text,text,timestamptz,timestamptz,jsonb) to authenticated;
grant execute on function public.submit_poll_ballot(uuid,jsonb) to authenticated;
grant execute on function public.my_poll_responses(uuid) to authenticated;
grant execute on function public.poll_results(uuid) to anon,authenticated;

-- After signing in once using the future administrator email:
-- insert into public.poll_admins(user_id)
-- select id from auth.users where email='admin@example.com' on conflict do nothing;
-- To authorise voting members:
-- insert into public.poll_voters(email) values
-- ('member1@example.com'),('member2@example.com') on conflict do nothing;
