# DEPLOYED — Vortex Kanba runbook

**Production URL:** https://vortex-kanba.vercel.app
**Deployment target:** Vortex design team (internal)
**Status:** MVP deploy — labeled internal/test-only until custom SMTP is wired up
**Upstream:** [Kanba-co/kanba](https://github.com/Kanba-co/kanba) (MIT)

---

## Architecture

| Layer | Technology |
|---|---|
| Framework | Next.js 13.5.1 (App Router), React 18.2.0, TypeScript |
| UI | Tailwind CSS + shadcn/ui + Radix primitives, `@hello-pangea/dnd` for drag-and-drop |
| Auth | **Supabase Auth** via `@supabase/supabase-js` (NOT NextAuth, despite what `.env.example` suggests) |
| Database | Supabase Postgres 17, project `vortex-kanba` (ref `hyehmskimkdanviivsrt`), region `eu-north-1` |
| ORM | Prisma 5.22 — used only for build-time client generation and (unused) Stripe routes |
| Hosting | Vercel (project `vortex-kanba`, scope `a5labs`) |
| Billing | **Stripe disabled** — internal tool, no subscriptions |

Kanba is **isolated from the main Vortex stack**:
- Separate Supabase project (not the Vortex Supabase)
- Separate Vercel project
- Separate GitHub fork (`vitaliirizol-lgtm/vortex-kanba`)
- No changes to Vortex's Supabase schema, RLS, audit log, or n8n workflows

---

## Environment variables

Set in **Vercel → Project Settings → Environment Variables**. Values are redacted.

| Name | Environments | Used by | Notes |
|---|---|---|---|
| `DATABASE_PROVIDER` | production, preview | `lib/database.ts` adapter selection | Always `supabase` |
| `NEXT_PUBLIC_SUPABASE_URL` | production, preview | `lib/supabase.ts` (client) | Public; also in `.env.local` |
| `NEXT_PUBLIC_SUPABASE_ANON_KEY` | production, preview | `lib/supabase.ts` (client) | Public; JWT anon key |
| `SUPABASE_SERVICE_ROLE_KEY` | production | `app/api/stripe/*/route.ts` only | Dead code with Stripe off — kept for completeness |
| `DATABASE_URL` | production, preview | Prisma runtime (transaction pooler) | Port 6543, `?pgbouncer=true&connection_limit=1` |
| `DIRECT_URL` | production, preview | Prisma build-time introspection (session pooler) | Port 5432 |
| `NEXT_PUBLIC_SITE_URL` | production | Supabase auth redirects, Stripe | `https://vortex-kanba.vercel.app` |

**Deliberately not set:** `STRIPE_SECRET_KEY`, `NEXT_PUBLIC_STRIPE_PUBLISHABLE_KEY`, `STRIPE_WEBHOOK_SECRET`, `NEXTAUTH_URL`, `NEXTAUTH_SECRET`. The NextAuth vars appear in `.env.example` but are not referenced anywhere in `.ts`/`.tsx` source — verified via `gh search code`.

### Supabase connection strings (the shape that works)

Both use Supavisor (shared pooler) — IPv4-reachable by default, no `$4/mo` dedicated IPv4 add-on needed:

```
DATABASE_URL=postgresql://postgres.hyehmskimkdanviivsrt:<DB_PASSWORD>@aws-1-eu-north-1.pooler.supabase.com:6543/postgres?pgbouncer=true&connection_limit=1
DIRECT_URL=postgresql://postgres.hyehmskimkdanviivsrt:<DB_PASSWORD>@aws-1-eu-north-1.pooler.supabase.com:5432/postgres
```

The direct endpoint `db.<ref>.supabase.co:5432` is IPv6-only — it does **not** work from most dev machines. Always use the pooler.

---

## Deploy command

```bash
cd ~/Documents/GitHub/vortex-kanba
vercel --prod --yes
```

That's it. `vercel.json` handles the rest:
- `buildCommand: npm run vercel-build` (= `prisma generate && next build --debug`)
- `framework: nextjs`
- `regions: ["iad1"]` — Vercel region is US East; Supabase is EU North. Cross-Atlantic latency is ~120ms on DB calls; tolerable for an internal tool. Change to `arn1` in `vercel.json` if it becomes a pain point.

The first deploy takes ~1 min. Subsequent deploys hit cache and finish in ~30s.

---

## Rollback

Two paths:

1. **CLI:** `vercel rollback` — reverts to the previous production deployment.
2. **Dashboard:** Vercel → Project → Deployments → pick a prior READY deployment → ⋯ → **Promote to Production**.

Both are instant — traffic switches at the edge without a rebuild.

---

## Database migrations (reapplying on a fresh project)

**Do not use `supabase db push`.** Upstream migrations have three issues on a fresh DB:

1. **Ordering is broken.** The `20240710*` and `20250101*` migrations ALTER tables that aren't created until `20250621152739_winter_tower.sql`.
2. **Duplicate policy names.** `20250621180532_snowy_lodge.sql` DROPs old policy names but CREATEs under new names that a prior migration already created.
3. **Wrong-signature function-as-trigger.** `20250621182625_patient_boat.sql` tries to use `refresh_user_accessible_projects()` (returns void) as a trigger function (needs to return trigger).

The fork commits three minimal patches (labeled `vortex-kanba fork:` in each file) plus the ordering script at [scripts/apply-migrations.sh](scripts/apply-migrations.sh).

```bash
# From a clean working tree
SUPABASE_PAT=sbp_xxx SUPABASE_REF=hyehmskimkdanviivsrt scripts/apply-migrations.sh
```

The script bypasses the Supabase CLI entirely and applies each migration via the Management API. No DB password needed — the PAT authenticates.

---

## Bootstrap: adding teammates

**The Kanba UI invite button is gated behind `subscription_status='pro'`** (verified in `components/team-management.tsx` and migration `20250621172000_round_crystal.sql`). Since we don't run Stripe, invites don't work out of the box.

### Option A — Self-signup + SQL insert (recommended)

1. Designer signs up at https://vortex-kanba.vercel.app/signup with their `@aceguardian.co` email. Email confirmation is **off** (Supabase → Auth → Providers → Email → "Confirm email" disabled), so they can log in immediately.
2. Admin opens Supabase dashboard → **Table editor** → `project_members`.
3. Admin inserts one row per designer:
   - `project_id` = copied from `projects` table (e.g. the `Design Team Board` ID)
   - `user_id` = copied from the designer's `profiles.id` (look them up by email)
   - `role` = `member` or `admin`
4. Designer refreshes — the project appears in their dashboard.

### Option B — Flip admin to Pro, use the UI

One-liner in Supabase → **SQL editor**:

```sql
UPDATE profiles
SET subscription_status = 'pro'
WHERE email = 'vitalii.rizol@aceguardian.co';
```

After this the admin can use Kanba's invite button directly. There's no actual Stripe subscription behind it — we're just flipping the gate.

### SMTP caveat

Default Supabase SMTP is rate-limited (~3/hour) and delivers from `noreply@mail.app.supabase.io`. Fine for a small design team doing password resets occasionally; **bad** for production invite flows at scale. To upgrade, see [Known limitations](#known-limitations).

---

## Pulling upstream updates

```bash
cd ~/Documents/GitHub/vortex-kanba
git fetch upstream
git merge upstream/main               # or git rebase upstream/main
# resolve any conflicts — three migration files have local patches
npm install
npx prisma generate
vercel --prod                         # if any migration changed, also re-run scripts/apply-migrations.sh
```

Expect conflicts on:
- `supabase/migrations/20250621180532_snowy_lodge.sql`
- `supabase/migrations/20250621180724_heavy_darkness.sql`
- `supabase/migrations/20250621182625_patient_boat.sql`

Each conflict is isolated to a small block marked `vortex-kanba fork:`. Keep both sides or re-apply the patch as needed.

---

## Vortex-specific modifications (diff vs upstream)

| File | What changed | Why |
|---|---|---|
| `.gitignore` | Added `supabase/.temp/` | CLI scratch dir from `supabase link` shouldn't be committed |
| `supabase/migrations/20250621180532_snowy_lodge.sql` | Added DROP POLICY IF EXISTS for 4 new policy names | CREATEs collided with policies created by earlier migrations under these names |
| `supabase/migrations/20250621180724_heavy_darkness.sql` | Removed 2 DROP FUNCTION IF EXISTS | Dropping fails on fresh DB because policies depend on the functions; `CREATE OR REPLACE` below handles redefine fine |
| `supabase/migrations/20250621182625_patient_boat.sql` | Removed broken CREATE TRIGGER block | Tried to use void-returning function as trigger; `precious_credit` (next migration) does it correctly |
| `scripts/apply-migrations.sh` (new) | Management API migration runner with corrected ordering | `supabase db push` can't handle the upstream ordering |
| `DEPLOYED.md` (this file) | Runbook | Operator documentation |

All changes are on the `main` branch of the fork. No long-lived feature branch.

---

## Day-1 seed (what should be in the workspace on first login)

- **Project:** `Design Team Board`
- **Columns** (in order, left to right): `Design Backlog` → `In Progress` → `Review` → `Ready for Dev` → `Done`
- **Sample tasks** (at least 3, so the board isn't empty):
  - Backlog: `[UX] Audit current onboarding flow` (priority: medium)
  - In Progress: `[UI] New empty-state illustrations for Home` (priority: high)
  - Done: `[Research] Competitor analysis Q2 2026` (priority: low, is_done: true)

**Labels note:** the brief asked for labels (UX, UI, Research, Brand, Prototype, Blocked), but Kanba's schema has **no labels table** — only `priority` (low/medium/high) and `is_done` (boolean). We're using a title-prefix convention `[UX]`, `[UI]`, etc. until upstream adds labels.

---

## Known limitations

1. **SMTP is Supabase default** — sender is `noreply@mail.app.supabase.io`, rate-limited to ~3 emails/hour on free tier. Email confirmation is currently **disabled** (`mailer_autoconfirm=true`) to avoid bottlenecking signups. Upgrade path: Supabase dashboard → Settings → Auth → SMTP Settings → Resend or Postmark with DNS for `aceguardian.co`.
2. **No custom domain** — using the default `*.vercel.app`. Add a custom domain (e.g. `kanba.aceguardian.co`) via Vercel → Project → Domains when desired.
3. **No GitHub OAuth** — email/password only. Supabase → Auth → Providers → GitHub to add later.
4. **Stripe disabled** — no paid tiers. The Stripe routes at `app/api/stripe/*` still exist but won't work until env vars are set. `/dashboard/billing` will break if visited.
5. **No native labels** — schema gap in upstream; workaround: title prefixes or `priority`.
6. **Pro-gated invites** — UI invite button hidden unless `subscription_status='pro'`. See [Bootstrap](#bootstrap-adding-teammates).
7. **Vercel region mismatch** — app deploys to `iad1` (US East), DB is in `eu-north-1` (Stockholm). ~120ms DB round-trip added. Fix: edit `vercel.json` → `"regions": ["arn1"]` and redeploy.
8. **No bridge to Vortex** — Kanba tasks are not mirrored into `app.requests` / `app.tasks` in the Vortex Supabase. Future n8n workflow could sync them nightly.

---

## Credentials vault (what to keep safe, where)

| What | Where it lives now | Rotation |
|---|---|---|
| Supabase PAT (`sbp_...`) | Only in the operator's password manager | Regenerate via https://supabase.com/dashboard/account/tokens; used by `scripts/apply-migrations.sh` |
| Supabase anon key | Vercel env + `.env.local` | Long-lived JWT; rotate only if exposed |
| Supabase service_role key | Vercel env only | Secret; rotate if exposed. Note Kanba only uses it in Stripe routes |
| DB password | Vercel env (as part of `DATABASE_URL`/`DIRECT_URL`) + `.env.local` | Reset via Supabase dashboard → Database → Reset database password; after reset, update all 4 env slots (prod + preview × DATABASE_URL + DIRECT_URL) |
| Vercel token (`vca_...`) | Operator's Mac keychain via `vercel login` | Revoke via Vercel → Account Settings → Tokens |

**Never commit any of these.** `.env.local` is gitignored; `.vercel/` is gitignored by Vercel CLI.
