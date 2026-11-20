-- MATES / OpenPoll: Reset the Masrur administrator verification code.
-- IMPORTANT: This GitHub file is PUBLIC. Do not put your real digits here.
-- 1. Copy this whole file into the Supabase SQL Editor.
-- 2. Replace YOUR_FOUR_DIGITS below with your intended 4-digit code IN SUPABASE ONLY.
-- 3. Click Run. Do not save or commit the edited code to GitHub.
-- 4. Check that the result shows one updated member with zero failed attempts.
--
-- Project SQL Editor:
-- https://supabase.com/dashboard/project/icdbowlocgwbksstritz/sql

DO $reset_masrur$
DECLARE
    v_pin text := 'YOUR_FOUR_DIGITS';
    v_count integer;
BEGIN
    IF v_pin !~ '^[0-9]{4}$' THEN
        RAISE EXCEPTION 'Replace YOUR_FOUR_DIGITS with exactly four numeric digits before running.';
    END IF;

    UPDATE public.mates_members AS m
    SET
        pin_hash = extensions.crypt(v_pin, extensions.gen_salt('bf', 10)),
        failed_attempts = 0,
        locked_until = NULL
    WHERE m.first_name = 'Masrur';

    GET DIAGNOSTICS v_count = ROW_COUNT;

    IF v_count <> 1 THEN
        RAISE EXCEPTION 'Expected one Masrur record but updated % rows. Verify the member name first.', v_count;
    END IF;

    RAISE NOTICE 'Masrur administrator verification reset successfully.';
END;
$reset_masrur$;

-- Verification: no private code or hash is displayed.
SELECT first_name, failed_attempts, locked_until
FROM public.mates_members
WHERE first_name = 'Masrur';
