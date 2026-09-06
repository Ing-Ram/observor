# observor

A native macOS menu-bar app that monitors the live web apps — **ggyst**,
**weblog** (chadingramcx.com) and **blog** (yappinblog.netlify.app) — for
uptime and traffic.

![The observor dashboard: status cards for ggyst, Portfolio and Yappin' plus
the Supabase dependency, each with latency and 24h uptime; visit and pageview
totals; a per-app table; and a visits-per-week chart.](docs/screenshot.png)

The strip under each status card is 24 hours of history, newest at the right —
green where a probe succeeded, red where it failed, grey where observor wasn't
running to measure.

## How it's split, and why

Uptime is measured **entirely from this Mac**: observor makes an outbound GET to
each site on a timer and stores the result in a local SwiftData store. No server
is involved.

Visits are different. A visitor's browser has to POST the pageview somewhere
publicly reachable, and a Mac app on a desk is not. So each site carries a small
beacon that writes to **Supabase** — the project that already backs the blog —
and observor reads the aggregates back with the service_role key.

```
ggyst  ─┐
weblog ─┼─ beacon POST ─> Supabase REST ─> observor_events
blog   ─┘                                  observor_errors
                                                │
        observor.app  ──────read────────────────┘
        └── probes the 3 sites directly for uptime → local SwiftData
```

The consequence worth remembering: **uptime history has gaps whenever observor
isn't running.** The strip shows those as grey, which means "not measured", not
"down". Visit counts have no such gap — they accumulate in Supabase whether or
not this app is open.

## Apps vs. dependencies

`observor_apps` rows carry a `kind`:

- **`app`** — generates traffic. Gets a series color, a chart bar, visit counts.
- **`dependency`** — infrastructure the apps sit on. Uptime only, neutral
  swatch, absent from the visit views.

Supabase itself is seeded as a dependency, and it is the reason the distinction
exists. The blog is a **static SPA**: Netlify returns a healthy 200 whether or
not Supabase is serving, because posts are fetched client-side. A green blog
card therefore says nothing about whether the blog actually works. The Supabase
row closes that gap by doing an authenticated PostgREST read of
`observor_apps` — a table observor owns, so the probe never depends on another
app's schema. Rows come back only if the database is genuinely serving.

A 401/403 on that probe is reported as **"Key rejected — check Settings"**, not
as an outage, so a config mistake doesn't send you hunting a phantom failure.

## Setup

1. **Apply the schema.** Paste `Vibe_Projects/blog/supabase/observor-schema.sql`
   into the Supabase SQL editor and run it. It is idempotent. It creates
   `observor_apps` (seeded with the three apps), `observor_events`,
   `observor_errors`, and two aggregate views.

2. **Deploy the beacons.** Already wired into all three repos; they activate as
   soon as the env vars are present.

   | App | Vars to set in the host's env |
   |---|---|
   | weblog | `VITE_SUPABASE_URL`, `VITE_SUPABASE_ANON_KEY` |
   | blog | already set |
   | ggyst | `NEXT_PUBLIC_SUPABASE_URL`, `NEXT_PUBLIC_SUPABASE_ANON_KEY` (set these in **Vercel** — `next.config.ts` reads the URL at build time to add the origin to `connect-src`) |

   The beacon no-ops on `localhost`, so local dev never pollutes the numbers.

3. **Run observor.** Open `observor.xcodeproj` and hit run. Then
   **Settings → Connection** and paste the Supabase URL and the **service_role**
   key (Project Settings → API). The key is stored in the login Keychain.

   Code signing is optional for local use — with no `Local.xcconfig` the app
   builds ad-hoc as "Sign to Run Locally", which is enough to run it. To sign
   with your own Apple developer account, copy the template and fill in your
   Team ID:

   ```sh
   cp Local.xcconfig.example Local.xcconfig
   ```

   `Local.xcconfig` is gitignored, so your Team ID stays on your machine.

   The anon key will not work for reading: the tables have no public select
   policy on purpose, so your traffic data is not world-readable.

Uptime works before any of this — with no credentials, observor falls back to
the targets hard-coded in `AppMonitor.swift` and starts probing immediately. The
Supabase dependency is the one exception: it needs a key, so it stays "not
measured" until Settings is filled in.

## Adding a fourth app

Insert a row into `observor_apps` (`slug`, `name`, `url`, optional
`health_path`) and add the beacon to that site with the new slug. observor picks
it up on the next refresh — no rebuild. Note that `Theme.swift` pins validated
series colors for the first three slugs; a fourth gets a stable fallback hue,
and going past three series means re-running the palette validator.

## Layout

| File | Purpose |
|---|---|
| `ObservorApp.swift` | `@main`; the `Window` + `MenuBarExtra` + `Settings` scenes |
| `AppMonitor.swift` | `@Observable` root state, refresh loops, uptime history queries |
| `SupabaseClient.swift` | Read-only PostgREST client |
| `HealthChecker.swift` | Outbound probes and the up/down verdict |
| `KeychainSecretStore.swift` | service_role key storage |
| `Models.swift` | Row types + the SwiftData `HealthSample` |
| `Theme.swift` | Validated palette, status colors, formatting |
| `DashboardView.swift` / `DashboardComponents.swift` | The window |
| `MenuBarView.swift` | The status-bar popover |
| `SettingsView.swift` | Connection + intervals |

## Health verdicts

An app with a `health_path` is judged by its response **body** — ggyst's
`/api/health` returns `{"status":"ready"}`, or 503 when its database is
unreachable, which is more truthful than the status code alone. Sites without
one are judged by status code, where 2xx and 3xx both count as up (a redirect to
`www` or to HTTPS is a working site).

## Later, if you want real 24/7 uptime

The smallest upgrade is a GitHub Action on a 5-minute cron writing into an
`observor_health` table, with observor reading that history instead of owning
it. Deliberately not built here — it trades the "no server" property for
coverage while the Mac is asleep.
