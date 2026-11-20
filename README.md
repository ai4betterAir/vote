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
