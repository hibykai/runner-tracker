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

1. Open `index.html` in a modern browser.
2. The **Manage Players** drawer opens automatically. Pick avatar colors, type a name, click **Add Player**.
3. Click the **🏃 Log Miles** button (bottom-right). Pick a date from the calendar, type miles, click **Log Miles**.
4. Watch your avatar glide east along Route 66.
5. Add more players with the **👥 Manage Players** button — they all share the same map and leaderboard.

## Tech

Single self-contained `index.html`. No build step, no dependencies. Vanilla HTML/CSS/JS with inline SVG for the map and avatars.

## License

MIT
