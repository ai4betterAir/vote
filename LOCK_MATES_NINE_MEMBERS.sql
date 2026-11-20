-- Apply AFTER mates-schema.sql. The approved MATES voter roster is fixed at nine.
-- This file does NOT include verification digits. It does not delete anyone.
-- It disallows using the former member-add/edit/delete functions from the website.
REVOKE ALL ON FUNCTION public.mates_admin_save_member(text,text,text,uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.mates_admin_delete_member(text,uuid) FROM PUBLIC, anon, authenticated;

create or replace function public.mates_create_election_admin(
 p_token text,p_title text,p_starts timestamptz,p_ends timestamptz,p_positions text[]
) returns uuid language plpgsql volatile security definer
set search_path=public,extensions,pg_temp as $$
declare new_id uuid; i int;
begin
 if not exists(select 1 from public.mates_admin_sessions s
   join public.mates_members a on a.id=s.member_id
   where s.token_hash=encode(digest(coalesce(p_token,''),'sha256'),'hex')
   and s.expires_at>now() and a.first_name='Masrur') then
   raise exception 'Administrator verification expired'; end if;
 if char_length(btrim(coalesce(p_title,''))) not between 3 and 120
   or p_starts is null or p_ends is null or p_ends<=p_starts or p_ends<=now()
   or coalesce(array_length(p_positions,1),0) not between 1 and 20
 then raise exception 'Invalid election title, dates or positions'; end if;
 if (select count(distinct lower(btrim(t))) from unnest(p_positions) t)<>array_length(p_positions,1)
   or exists(select 1 from unnest(p_positions) t where char_length(btrim(coalesce(t,''))) not between 2 and 70)
 then raise exception 'Position titles must be unique and nonempty'; end if;
 if (select count(*) from public.mates_members) <> 9 or
   (select count(*) from public.mates_members
    where first_name in ('Masrur','AbdulAhad','Akter','Rubel','Anwar','Numan','Sakil','Shamim','Turab')) <> 9 then
   raise exception 'Nine approved voters must be loaded before publishing';
 end if;
 insert into public.mates_elections(title,starts_at,ends_at)
 values(btrim(p_title),p_starts,p_ends) returning id into new_id;
 for i in 1..array_length(p_positions,1) loop
   insert into public.mates_positions(election_id,title,sort_order)
   values(new_id,btrim(p_positions[i]),i);
 end loop;
 return new_id;
end; $$;

REVOKE ALL ON FUNCTION public.mates_create_election_admin(text,text,timestamptz,timestamptz,text[])
 FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.mates_create_election_admin(text,text,timestamptz,timestamptz,text[])
 TO anon, authenticated;
NOTIFY pgrst, 'reload schema';
