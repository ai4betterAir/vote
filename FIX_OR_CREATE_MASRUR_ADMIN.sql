-- OpenPoll / MATES: Create or reset Masrur admin member safely.
-- PUBLIC TEMPLATE: NEVER save a real phone suffix or PIN to GitHub.
-- Copy this SQL to your Supabase SQL Editor and replace the placeholder
-- with a NEW four-digit code there only. Because an earlier code was shared
-- in chat, use a different code before activating real voting.
--
-- This script inserts Masrur if no record exists, otherwise updates the
-- matching first-name record (case / surrounding whitespace insensitive).
-- No other member is changed, and no PIN or hash is displayed.

DO $admin_setup$
DECLARE
    v_pin text := 'YOUR_NEW_FOUR_DIGITS';
    v_member_id uuid;
    v_matches integer;
BEGIN
    IF v_pin !~ '^[0-9]{4}$' THEN
        RAISE EXCEPTION 'Replace YOUR_NEW_FOUR_DIGITS with exactly four digits in Supabase before running.';
    END IF;

    SELECT COUNT(*)
      INTO v_matches
      FROM public.mates_members m
     WHERE lower(btrim(m.first_name)) = 'masrur';

    IF v_matches > 1 THEN
        RAISE EXCEPTION 'Multiple Masrur-like records exist. Resolve duplicates before proceeding.';
    ELSIF v_matches = 1 THEN
        SELECT m.id
          INTO v_member_id
          FROM public.mates_members m
         WHERE lower(btrim(m.first_name)) = 'masrur';

        UPDATE public.mates_members
           SET first_name = 'Masrur',
               pin_hash = extensions.crypt(v_pin, extensions.gen_salt('bf', 10)),
               failed_attempts = 0,
               locked_until = NULL
         WHERE id = v_member_id;
        RAISE NOTICE 'Updated existing Masrur record.';
    ELSE
        INSERT INTO public.mates_members
            (first_name, pin_hash, failed_attempts, locked_until)
        VALUES
            ('Masrur', extensions.crypt(v_pin, extensions.gen_salt('bf', 10)), 0, NULL)
        RETURNING id INTO v_member_id;
        RAISE NOTICE 'Created missing Masrur record.';
    END IF;
END;
$admin_setup$;

-- Safe verification: shows only member name and account lock status.
SELECT first_name, failed_attempts, locked_until
  FROM public.mates_members
 WHERE lower(btrim(first_name)) = 'masrur';

-- Check how many first-name records are actually saved:
SELECT count(*) AS registered_member_count FROM public.mates_members;

NOTIFY pgrst, 'reload schema';
