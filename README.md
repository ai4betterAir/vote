# CommitteeVote

Executive committee election website for GitHub Pages. Positions can share the same candidates. Signed-in approved voters submit exactly one complete ballot per election. Results are only available in horizontal bar charts once the poll closes.

## Publishing on GitHub Pages
1. Go to **Settings → Pages** in [this repository](https://github.com/ai4betterAir/vote).
2. Choose **Deploy from a branch**, **main**, **/(root)**, and save.
3. The site URL is **https://ai4betterair.github.io/vote/**.

## Setting up secure voting
GitHub Pages hosts only static files. Supabase stores votes and enforces closing times.

1. Create a Supabase project: https://supabase.com/dashboard
2. In **SQL Editor**, execute the entire [schema.sql](schema.sql).
3. Under **Authentication → Providers**, enable Email / Magic Link.
4. In **Authentication → URL Configuration**, set Site URL to `https://ai4betterair.github.io/vote/` and add that URL to Redirect URLs.
5. In **Project Settings → API**, copy the **Project URL** and the **publishable (anon) key**. Edit `index.html` to replace `SUPABASE_URL_HERE` and `SUPABASE_ANON_KEY_HERE`. A publishable/anon key is safe for browser use; **never expose a service role/secret key**.
6. Sign in to the website once with the intended administrator email. Then execute:
   ```sql
   insert into public.election_admins(user_id)
   select id from auth.users where email='ADMIN_EMAIL@example.com'
   on conflict do nothing;
   ```
   Sign out/in, then the **Create poll** button will appear.
7. Add authorised voters in Supabase SQL Editor:
   ```sql
   insert into public.voter_allowlist(email)
   values ('voter1@example.com'),('voter2@example.com')
   on conflict do nothing;
   ```
8. Create a poll on the website, using Sydney local time. Members sign in with their authorised email to vote.

## Election rules

- Every candidate appears for every position. One candidate must be selected per position.
- One complete ballot per verified, allowlisted email account; database uniqueness prevents duplicates even during concurrent requests.
- Browser-side counts are not used; results are fetched from a server-side function that checks the closing time.
- Results are expressed as vote counts and percentages for each position. No voter identities or individual choices are exposed to other voters.
- The demo/initial site does **not** support changing ballots after submission, poll editing, multi-seat positions, or ranked-choice voting.
- Email verification confirms access to a mailbox, not a person's identity. Administrators should keep the allowlist controlled.
- For highly consequential or anonymous secret-ballot elections, seek an independently audited election service: administrators of this database can inspect individual votes.
