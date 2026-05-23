# Coast to Coast Run

A browser-based running tracker game where players race their avatars across a map of the United States from Santa Monica, CA to New York, NY along a Route 66 + I-80 corridor. Each mile a player runs in real life moves their avatar proportionally along the ~3,040-mile route. First player to reach NYC wins.

## Features

- **Customizable avatars** — pick skin tone, shirt, shorts, and hat colors for each player
- **Real geography** — 48 lower-48 US states rendered from lat/lon polygons via a pseudo-Albers projection; running 50 miles moves the avatar ~22 px (about 1.4 % of the map width), proportional to real distance
- **Real road distances** — actual mile gaps between every city on the route (Santa Monica → Barstow = 113 mi, Amarillo → Oklahoma City = 260 mi, etc.)
- **Custom date picker** — click the date button, pick a day from a calendar grid (no manual typing)
- **Leaderboard** — top-right of the map, ranked by total miles, with a 🏆 next to anyone past the 2,790-mile finish line
- **Smooth avatar movement** — CSS transition animates the avatar along the route when miles are logged
- **Zoomable map** — drag to pan, scroll-wheel or buttons to zoom; click any avatar to zoom to its current state and route segment
- **Persistence** — every player, log, and avatar config is stored in `localStorage` and survives reloads

## How to play

### Solo (offline)

1. Open `index.html` in a modern browser.
2. On the landing screen, click **Play solo** (or skip the landing if multiplayer is not configured).
3. The **Manage Players** drawer opens. Pick avatar colors, type a name, click **Add Player**.
4. Click the **🏃 Log Miles** button. Pick a date from the calendar, type miles, click **Log Miles**.
5. Watch your avatar glide east along Route 66.
6. Add more players with the **👥 Manage Players** button — they all share the same map and leaderboard on this one browser.

### Multiplayer (with friends on different computers)

1. Click **Create a lobby** on the landing screen. Pick a name, customize your avatar, hit Create.
2. You'll be shown a **4-word recovery passphrase** — write it down somewhere safe. Share the **lobby link** (or just the 6-character code) with your friends.
3. Friends open the link, customize their avatar, type their name, and click Join.
4. Everyone sees the same map, leaderboard, and avatars in real time as each player logs miles.
5. Private lobbies are the default — only people with the code can join. The admin (lobby creator) can kick members, regenerate the code, or transfer admin to someone else.
6. If you wipe your browser storage, paste the recovery passphrase on the landing screen to take back the admin role.

## Multiplayer setup (one-time, for the lobby host)

The app is a static file but multiplayer needs a backend. Supabase has a free tier that's enough for friends-only races.

1. **Create a Supabase project** at <https://supabase.com> (free tier is fine).
2. **Enable anonymous sign-ins**: Authentication → Sign In / Up → toggle **Anonymous Sign-Ins** on.
3. **Run the schema migration**: SQL Editor → New query → paste the contents of [`supabase/migrations/0001_init.sql`](supabase/migrations/0001_init.sql) → Run.
4. **Copy your project URL and anon key** (Settings → API) into `index.html`:
   ```js
   const SUPABASE_URL      = 'https://YOUR-PROJECT.supabase.co';
   const SUPABASE_ANON_KEY = 'eyJhbG...';
   ```
   The anon key is meant to be public — Row-Level Security policies in the migration enforce that strangers can't write to lobbies they aren't members of.
5. **Host the file somewhere shareable** so friends can open the same URL: GitHub Pages, Cloudflare Pages, Netlify, Vercel — anything that serves a static HTML file works. The single `index.html` is the entire frontend.

If you skip these steps, the app still runs in solo mode without multiplayer. Open `index.html` directly via `file://` and play locally.

## Tech

Single self-contained `index.html` + a Supabase Postgres schema (`supabase/migrations/0001_init.sql`). No build step, no JS dependencies (Supabase client loaded via CDN). Vanilla HTML/CSS/JS with inline SVG for the map and avatars.

State persists in `localStorage` for solo mode and in a Postgres-backed Supabase project for multiplayer lobbies. Real-time sync between browsers uses Supabase Realtime postgres_changes channels (coming in Phase 4 — Phase 3 ships create/join + per-player state but requires a manual refresh to see others' updates).

## License

MIT
