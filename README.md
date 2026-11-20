# OpenPoll — flexible polling website

Public website: https://ai4betterair.github.io/vote/

OpenPoll is a general-purpose poll creator hosted on GitHub Pages. Polls can be about MATES EC Committee elections, other committees, events, preferences or surveys. No organisation logo or name is hard-coded.

## Features
- General-purpose homepage with **Create Poll**.
- Custom poll name and description.
- Start and closing time (entered in Sydney local time).
- Multiple questions, each with its **own** independent list of answer choices.
- Manual question builder: add/remove questions and choices.
- **JSON import and export** for creating structured polls programmatically.
- Email sign-in; administrator approval and voter email allowlist.
- One complete submission per voter per poll.
- Results only after the deadline, displayed as horizontal **bar charts** by question.

## Publish on GitHub Pages
In repository **Settings → Pages**, select **GitHub Actions** as the source. The included workflow deploys `index.html` from the `main` branch.

## Enable real voting
The website and poll design preview work without a backend, but a Supabase project is required for **publishing, voting and authentic results**.

1. Create a Supabase project at https://supabase.com/dashboard .
2. Open Supabase **SQL Editor** and execute [schema.sql](schema.sql) (this creates `polls`, `poll_questions`, `poll_options`, `poll_responses`, `poll_admins` and `poll_voters`).
3. Enable Supabase **Authentication → Providers → Email**. Enable email magic links.
4. In **Authentication → URL Configuration**, set Site URL and add Redirect URL: `https://ai4betterair.github.io/vote/`.
5. Copy Supabase **Project URL** and the **publishable/anon key** into `index.html` at the `config` object (`SUPABASE_URL_HERE`, `SUPABASE_ANON_KEY_HERE`). **Never publish the service_role key**.
6. Sign in once with the email to be used by your administrator, then run:
   ```sql
   insert into public.poll_admins(user_id)
   select id from auth.users where email='admin@example.com'
   on conflict do nothing;
   ```
   Replace the example email. Sign out and back in.
7. Authorise members using:
   ```sql
   insert into public.poll_voters(email) values
   ('member1@example.com'),('member2@example.com')
   on conflict do nothing;
   ```
8. Build your poll on the website and press **Publish poll**.

## Creating polls manually
Select **Create Poll**, type a title such as `MATES EC Committee Election`, choose opening/closing dates, then add question titles like `President`, `Vice President` and `Secretary`. Under each question, add the appropriate names. You may use the same names for multiple questions or different choices entirely.

## Creating polls with JSON
Choose **Create Poll → Import JSON**, paste the following and click **Apply JSON**. Review schedule fields before publishing.

```json
{
  "title": "MATES EC Committee Election",
  "description": "Choose executive committee members.",
  "questions": [
    {"title": "President", "options": ["Candidate A", "Candidate B", "Candidate C"]},
    {"title": "Vice President", "options": ["Candidate A", "Candidate B", "Candidate C"]},
    {"title": "Treasurer", "options": ["Candidate D", "Candidate E", "Candidate F"]}
  ]
}
```

**Export poll JSON** saves your unfinished design locally as a JSON file. Polls are currently single-choice per question.

## Important limitations
- Polls cannot be edited after publishing in this version. Check question text and close times first.
- All polls are publicly listed; only allowlisted, signed-in email holders can vote.
- The database, not browser time, checks closing deadlines and prevents early result access.
- Administrator access to database records is **not** the same as secret-ballot anonymity; database administrators can potentially link a vote to its voter. Do not use this as an independently audited or anonymous election system.
- Emails can be approved in the allowlist, but this does not independently verify a voter's offline identity.
- Creating any poll is restricted to configured administrators; if no administrator is configured, you can still design and export a poll JSON.

## MATES EC Committee — dedicated name-and-phone-check ballot

The site has an optional MATES election mode at **https://ai4betterair.github.io/vote/mates.html** while the general-purpose OpenPoll homepage remains available.

The five positions are **President**, **Secretary**, **Vice President**, **Joint Secretary**, and **Treasurer**. The candidate and voter roster comprises nine first names: Masrur, AbdulAhad, Akter, Rubel, Anwar, Numan, Sakil, Shamim, and Turab. Every verified voter sees the other eight members only; self-voting is prohibited by the database, not just the interface.

### Additional deployment steps for MATES

1. Complete general Supabase setup above (including administrator email authorisation), then execute **[mates-schema.sql](mates-schema.sql)** in Supabase SQL Editor.
2. Run the separately provided **PRIVATE MATES voter setup SQL** in Supabase SQL Editor. **Never commit that private file** or its four-digit checks to this public repository.
3. Set the **same Supabase Project URL and publishable/anon key** in `mates.html` as you set in `index.html` (two files).
4. Visit `mates.html`, use **Admin: Create election** and set start and end times. Only a signed-in authorised `poll_admins` user can publish it. Note that admin sign-in uses the general OpenPoll homepage.
5. The published election has a **Copy voting link** button. Share that link directly with the nine eligible members. Each selects their first name and enters the final four digits of their registered phone number to unlock their ballot.

A four-digit phone suffix is **knowledge-based verification**, not a real SMS/phone ownership check. The SQL protects stored checks with salted password hashes, limits wrong attempts per member (five attempts, one-hour lock), provides short-lived session tokens, enforces one ballot per voter, and rejects self-votes. However, four digits can still be guessed or known by others. For higher-stakes elections, require SMS OTP or an independently validated identity check.

Votes and individual selections are never publicly exposed; the bar-chart results are only returned by the database after the scheduled closing time. Database administrators may still access underlying ballot records. Polls cannot be modified after publication in the current version.
