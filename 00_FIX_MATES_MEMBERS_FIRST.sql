-- OpenPoll / MATES: STEP 1 — Repair missing member table and public member-list function.
-- Open Supabase > SQL Editor > New query, paste ALL of this file, then Run.
-- Safe to run again: creates missing objects without deleting existing member records.
-- This does NOT insert real member phone verification digits.
-- Do NOT put private phone digits, hashes or service role keys in this public repository.

CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE TABLE IF NOT EXISTS public.mates_members (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    first_name text NOT NULL UNIQUE,
    pin_hash text NOT NULL,
    failed_attempts integer NOT NULL DEFAULT 0,
    locked_until timestamptz
);

ALTER TABLE public.mates_members ENABLE ROW LEVEL SECURITY;

-- Members' phone digits and hashes must never be readable by browsers.
REVOKE ALL ON TABLE public.mates_members FROM anon, authenticated;

-- The browser can ask for FIRST NAMES ONLY. It cannot read private verification hashes.
CREATE OR REPLACE FUNCTION public.mates_member_names()
RETURNS TABLE (id uuid, first_name text)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, extensions, pg_temp
AS $function$
    SELECT m.id, m.first_name
    FROM public.mates_members AS m
    ORDER BY m.first_name;
$function$;

REVOKE ALL ON FUNCTION public.mates_member_names() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.mates_member_names() TO anon, authenticated;

NOTIFY pgrst, 'reload schema';

-- CONFIRMATION (the table should now exist, and this SELECT should run):
SELECT id, first_name
FROM public.mates_member_names();
