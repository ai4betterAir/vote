-- MATES election turnout / participant names.
-- Execute ONCE in Supabase SQL Editor after mates-schema.sql.
-- This publishes only first names and ballot submission times, never candidate choices.
-- The electorate has explicitly agreed to display participation names.
--
-- Returns a one-row-per-voter listing for a valid election.
-- All ballots are submitted atomically by mates_submit_ballot, so distinct
-- member IDs correspond to completed ballots.
CREATE OR REPLACE FUNCTION public.mates_voter_turnout(p_election uuid)
RETURNS TABLE (first_name text, voted_at timestamptz)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, extensions, pg_temp
AS $function$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM public.mates_elections e WHERE e.id = p_election
  ) THEN
    RAISE EXCEPTION 'Election not found';
  END IF;

  RETURN QUERY
  SELECT m.first_name::text, MIN(b.created_at)::timestamptz AS voted_at
  FROM public.mates_ballots b
  JOIN public.mates_members m ON m.id = b.member_id
  WHERE b.election_id = p_election
  GROUP BY m.id, m.first_name
  ORDER BY MIN(b.created_at), m.first_name;
END;
$function$;

REVOKE ALL ON FUNCTION public.mates_voter_turnout(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.mates_voter_turnout(uuid) TO anon, authenticated;
NOTIFY pgrst, 'reload schema';

-- Optional check: replace the UUID with an existing mates_elections.id.
-- SELECT * FROM public.mates_voter_turnout('00000000-0000-0000-0000-000000000000');
