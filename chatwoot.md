# Chatwoot — customer support helpdesk + AI agent

Self-hosted Chatwoot running "Barry", an AI support agent that answers customer email,
looks up real order status against this repo's API, and hands off to a human when it
doesn't know something.

Stood up 2026-09-06. Ported from the Klaviyo Customer Agent, which it replaces.

---

## Access

| | |
|---|---|
| Dashboard | https://customer-service.printoracle.com |
| Admin login | `support@printoracle.com` (user id 2; manually confirmed 2026-09-08, SuperAdmin and account administrator) |
| SSH | `gcloud compute ssh customer-service --project teeshirtpalacehosting --zone us-central1-a` |

If gcloud says "Reauthentication failed", run `gcloud auth login` — it can't prompt from
inside a Claude session.

## Infrastructure

| | |
|---|---|
| GCP project | `teeshirtpalacehosting` (same project as `print-oracle-new`) |
| VM | `customer-service`, `e2-small` (2 vCPU burst / 2 GB), `us-central1-a` |
| Disk | 30 GB pd-balanced |
| Static IP | `35.253.188.13` (reserved as `customer-service-ip`) |
| OS | Ubuntu 24.04 LTS + 4 GB swap, `vm.swappiness=10` |
| DNS | Cloudflare zone `printoracle.com`, A record `customer-service`, **proxy OFF (grey cloud)** |
| TLS | Caddy 2, automatic Let's Encrypt |
| App | Chatwoot 4.17.1 (Rails 7.2 + Vue, Sidekiq, Postgres/pgvector, Redis) |
| Infra cost | ~$15/mo |

**Grey cloud is required.** Cloudflare's orange-cloud proxy breaks Let's Encrypt HTTP-01
renewal and interferes with Chatwoot websockets.

## Layout on the box

**The box is deployed from a repo, not edited by hand.** Everything non-stock lives in
`~/Documents/chatwoot/deploy` (our fork of chatwoot/chatwoot, branch `develop`), and
`make launch` ships it. Editing files on the VM directly means the next deploy silently
reverts them; `make diff` from that folder reports any drift. See `deploy/README.md`.

Everything lands in `/opt/chatwoot`:

- `docker-compose.yaml` — 5 services: rails, sidekiq, postgres (pgvector/pg16), redis, caddy.
  Image pinned to `chatwoot/chatwoot:v4.17.1` (not `:latest` — upgrade deliberately, after a
  snapshot). Per-container `mem_limit` so Sidekiq can't starve Rails on a 2 GB box:
  rails 900m, sidekiq 700m, postgres 400m, redis 120m.
- `.env` — mode 600. `FRONTEND_URL`, `FORCE_SSL=true`, `ENABLE_ACCOUNT_SIGNUP=false`,
  `CAPTAIN_OPEN_AI_API_KEY` (our own OpenAI key), `CAPTAIN_OPEN_AI_MODEL=gpt-5.5`,
  `INSTALLATION_PRICING_PLAN=enterprise`.
- `Caddyfile` — `customer-service.printoracle.com { reverse_proxy rails:3000 }`
- `backup.sh` + `/etc/cron.d/chatwoot-backup` — nightly 03:00 `pg_dump`, 7-day retention.
- `patches/` — our Ruby changes, mounted into rails and sidekiq at
  `config/initializers/printoracle/`. See "Our patches" below.

`.env` and `backups/` are the only things that live *only* on the server; a deploy never
reads or overwrites either.

Rails port 3000 is **not** published to the host; Caddy reaches it over the Docker network.
So `curl localhost:3000` on the VM fails by design — probe the public URL instead.

Do not add a `base:` service to the compose file. Chatwoot's published compose uses one as a
YAML anchor, which with `restart: always` becomes a container that restart-loops forever.
Our file uses a top-level `x-base: &base` extension field instead.

---

## How Barry is configured

Captain assistant "Barry", account "Print Oracle". All of it is data in Postgres, set in the
dashboard under Captain — the one exception is the per-channel handoff copy, which needs the
patch described in "Our patches".

- **7 FAQ snippets** ported from the Klaviyo agent — support hours, shipping/payment,
  order tracking, return policy, artwork requirements, TCHAT10 discount rule.
- **7 guardrails** — the handoff rules. See the gotcha below about why they're guardrails
  and not "Instructions".
- **6 response guidelines** — tone and format.
- **133 crawled pages** from printoracle.com, embedded with `text-embedding-3-small`.
  (Klaviyo's crawl of the same site failed; Chatwoot's succeeded.)
- **1 custom tool** — `print_oracle_order_status`, see below.
- **Handoff message** — per channel, since the two read very differently:
  email/API gets "I'm getting a teammate to help with this. They'll reply right here, and
  you'll get an email too if you step away."; live chat gets "I've made a ticket for this.
  A teammate will get back to you by the next business day." Chat text is
  `config['handoff_message_chat']`, which only exists because of our patch — upstream has
  one handoff message per assistant.
- **Model** — `gpt-5.5`. Read the model gotcha before changing this.

Verified working: 8/8 handoff test matrix, live order lookup returning FedEx tracking,
correct inference on questions not explicitly covered (e.g. that an `.AI` file isn't on the
accepted-formats list).

### Shortcut knowledge review (2026-09-08)

Reviewed the owner's legacy support shortcuts against Barry's 10 existing FAQs,
133 stored documents, and product/order tools. Added 13 approved FAQs (#11–23)
with descriptive question titles: quote preparation, company services,
print-on-demand/dropshipping, combined bulk discounts, artwork help and approval,
two-sided full-color Zip Tote printing, embroidery digitizing, printing methods,
maximum DTG size, exact logo dimension requests, rewards, carriers, and local pickup.
Updated existing discount FAQ #6 with the missing **10% off** detail for TCHAT10.

Skipped duplicate policies/contact information, generic human chat scripts,
ticket/action-completed claims, the blank-order workaround, and order-first sleeve
instructions. Kept existing hours (10 AM–5 PM Eastern) and handling time (2–4
business days); the supplied shortcuts instead said 9 AM and 1–3 days, so those
conflicting versions were not imported. Product materials, care, and sizing remain
covered by the existing style tool. Guardrails and response guidelines were unchanged.

Most stored crawls stop at 15,000 characters of navigation, before the page's useful
body; a listed document alone is not evidence that Barry knows its contents.
The additions above fill missing facts as directly searchable FAQs. A database
backup ran before the update. Verified all 23 FAQs, approved status and embeddings
for all 14 changed records, preservation of the other 9 FAQs, and 13/13 paraphrased
queries through Captain's actual FAQ lookup tool. No customer messages were sent.
These checks prove retrieval, not end-to-end model replies.

## Inboxes

| id | name | channel | Barry on? |
|---|---|---|---|
| 1 | Support Test | Api | yes |
| 2 | Support | Email | yes |
| 3 | Website Chat | WebWidget | yes (since 2026-09-08) |

Inbox 3 was added 2026-09-08 to trial Chatwoot live chat as a Tawk.to replacement.
Widget token lives in this repo's `.env` as `NEXT_PUBLIC_CHATWOOT_TOKEN`; unset it and
`components/Chat.tsx` falls back to Tawk. Widget code: `components/ChatwootChat.tsx`.

Attachment is a row in `captain_inboxes` (there is no `Captain::Inbox` constant — query the
table directly). Barry's handoff copy is email-shaped, so chat gets its own text via the
`channel_aware_handoff_message` patch below rather than a second assistant.

Anonymous web visitors have no email on the contact, so `print_oracle_order_status` gets an
empty `email` and 400s (same root cause as Captain gotcha 3). Logged-in visitors are fine —
the widget calls `$chatwoot.setUser` with the session email. For anonymous ones, either turn
on the inbox pre-chat form (asks for email before the first message) or let Barry ask.

## Integration with this repo

### Style information (live and connected 2026-09-08)

`GET /api/integrations/customer-service/style-info?query=PC54` uses the same
`x-api-key` / `CUSTOMER_SERVICE_ORDER_STATUS_API_KEY` as order lookup; no customer
email is needed. It matches style code or manufacturer model number first, then
product/brand names. PC54 resolves to internal style code AT.

Returns up to five customer-facing styles: model, brand, name, description,
features, catalog sizes/colors, product link, and structured size-chart values
with their stored units. Excludes inactive, admin-only, explicitly unpublished
styles, costs, and production configuration. Multiple matches are marked
`ambiguous`; missing structured measurements return `sizeChart: null`. Legacy
HTML-only charts are not interpreted. Catalog colors/sizes are not live inventory.

Validation: `npx vitest run tests/customerServiceStyleInfo.test.ts`. The handler
was also invoked against the real database and returned PC54's chart in inches.

After deploying the endpoint, run `scripts/configure-chatwoot-style-info.rb` in
the Chatwoot Rails container. It verifies live PC54 lookup before transactionally
creating/enabling `print_oracle_style_info` and replacing only the blanket product
handoff rule, plus adding sizing guidance. It reuses the order tool's auth without
printing secrets. Failure to verify the endpoint leaves the configuration intact.
Price quotes, live stock, missing facts, refunds, and defects still hand off.
Tool #2 (`print_oracle_style_info`) was enabled on 2026-09-08 after the live endpoint passed verification. Barry's product guardrail and sizing guideline were updated. A Captain V2 playground test called the actual tool for "What is the sizing for a PC54 in medium?" and answered with chest 20, length 29, and sleeve from center back 17 3/4 inches; `handoff_tool_called` was false. No customer message was sent. Combined brand/product phrases such as "Gildan hoodie" still need search improvement.

### Order status

Barry calls one endpoint here:

```
GET /api/integrations/customer-service/order-status
    ?email={{customer_email}}&orderNumber={{order_number}}
Header: x-api-key: <CUSTOMER_SERVICE_ORDER_STATUS_API_KEY>
```

- Route: `app/api/integrations/customer-service/order-status/route.ts`
- Key: `CUSTOMER_SERVICE_ORDER_STATUS_API_KEY` in `.env`
- Timeout 10s, 2 retries, configured Chatwoot-side.

**The payload is customer-facing by construction** (changed 2026-09-08). Barry repeats
whatever it is handed, and it was handing customers raw floor vocabulary: "In Bin: 3",
"DTF Load", "label Printed", plus pieceIds and SKUs. So the route no longer returns them.
`functions/orders/customerOrderView.ts` collapses every internal status into one of
`Awaiting payment` / `Awaiting artwork approval` / `Preparing` / `In production` /
`Ready to ship` / `Shipped` / `Delivered` / `Canceled`, unknown statuses falling back to
`Preparing` so a new station name can never leak. Items are grouped into
`"Duck Camo Trucker Hat, OSFA"` lines with a count instead of one row per piece, and
pieceId/sku/sellerSku/uniquePo are gone from the select entirely.

Each order also carries `customerSummary`, the finished sentence support should say, plus
`expectedShipBy` (order date + the style's max handling days, via
`functions/orderShipByDate.ts`) and `pastExpectedShipDate`.

Open item: `pastExpectedShipDate` is the hook for the late-order case Jerri Hanna hit on
2026-09-08. Nothing in Captain reads it yet. Add a guardrail requiring handoff when it is
true rather than letting Barry re-explain that the order is still processing.

Email is required and the lookup is by `userEmail`. Barry passes either the email the
customer typed in the message or the contact's email on file — whichever it has, and it
will try both if they differ.

**The key is stored in plaintext** in Postgres (`captain_custom_tools.auth_config` is
unencrypted jsonb), so it's in every DB dump and disk snapshot. It's short and guessable
and now internet-facing. Rotating it is an open item.

---

## Captain gotchas — read before changing config

These all fail silently, with no error in the UI. Each cost real debugging time.

**1. "Instructions" is a dead field.** `config['instructions']` is not rendered into the
Captain v2 agent prompt at all — only the v1 path and the action classifier read it.
Behavior rules must go in `guardrails` or `response_guidelines`. Moving the handoff rules
from Instructions to Guardrails took the test matrix from 4/8 to 8/8 with no other change.

**2. Handoff only fires if a guardrail explicitly demands it.** The v2 prompt says the model
may use the handoff tool "only after the user explicitly requests human assistance, accepts
your offer to speak with a human, or a Response Guideline or Guardrail explicitly requires
transfer for the matched condition." Default behavior is ask-permission-first. Write
guardrails as "you MUST transfer to a human immediately using the handoff tool. Do not ask
permission first."

On 2026-09-08, conversation 109 exposed a false handoff promise: FAQ lookup ran,
but the handoff tool did not, leaving the conversation pending. Added an active
guardrail requiring `captain--tools--handoff` before any transfer claim and forbidding
success claims if the tool fails. Configuration only; no Chatwoot application code changed.
Verification used a process-local handoff stub to prevent customer messages and
conversation mutations.
Five final tool-selection checks passed: two design-location questions clarified,
damage and explicit human requests called handoff, and a greeting did not.
These checks verify model tool selection, not end-to-end handoff delivery or a
guarantee that the model will always follow the guardrail.

**3. `feature_contact_attributes` must be on** or the model never sees the customer's email,
and any tool needing customer identity gets an empty param (this is why order lookups
returned 400 at first). It is not one of the checkboxes in the create-assistant dialog.

**4. The model must be one RubyLLM's bundled registry knows.** Chatwoot runs two LLM paths:
the reply path accepts any model string, but FAQ generation, the action classifier and
conversation-events go through RubyLLM, which validates model ids. An unknown model makes
replies work and then throws in a later async job, which Chatwoot's error handler turns into
an automatic handoff — so **every conversation answers and then immediately hands off**,
showing "Auto-handoff: Unknown model: X". This happened with `gpt-5.6-terra`.

`RubyLLM.models.refresh!` is not a fix: it only affects the process that runs it (Sidekiq
stays broken) and resets on restart. RubyLLM 1.15 knows OpenAI models up to the gpt-5.5
family and does not know gpt-5.6. Check first:

```ruby
RubyLLM.models.find("gpt-5.5")   # raises RubyLLM::ModelNotFoundError if unknown
```

**5. Handoff always posts a customer-visible message.** Blanking `handoff_message` just
restores the default text. Silent handoff is not configurable. The handoff *reason* is a
separate private note, agent-only.

**6. Custom tools are HTTPS-only**; `localhost` and `*.local` are blocked. GET params go in
`endpoint_url` via `{{param}}` templating. The embedding column is hard-coded `vector(1536)`,
so `text-embedding-3-small` only — `text-embedding-3-large` (3072 dims) breaks inserts.

## Our patches

Ruby files in `deploy/patches/`, mounted into rails and sidekiq as
`config/initializers/printoracle/`. Rails globs `config/initializers/**/*.rb`, so a new
file there loads on boot with no compose change. Each one uses
`Rails.application.config.to_prepare` + `prepend`, never a load-time constant edit.

Mounted as a **directory**, not file by file: a file bind-mount keeps the old inode when
the file is replaced, so a deploy would ship a change the container never sees.

### `imap_lock_to_single_conversation.rb`

`Inbox#lock_to_single_conversation` is honoured by `ConversationBuilder` and the
WhatsApp/SMS/Facebook/Telegram services, but **not** by email:
`Imap::ImapMailbox#find_or_create_conversation` calls `Conversation.create!` directly.

Email therefore threads *only* on `In-Reply-To`/`References`. A customer who composes a
fresh message each time instead of replying gets a new conversation per email, and Barry
answers each one with no history — on 2026-09-08 one contact generated 20 conversations in
40 minutes and got contradictory answers plus five separate handoffs. Their inbound mail
had `subject=""`, `in_reply_to=nil`, `references=[]`; the one message they actually
replied to threaded correctly.

The patch makes the email path check the flag. Inbox 2 has
`lock_to_single_conversation: true`. Verified live: messages before the deploy landed in
conversations 132–136, messages after all landed in 137.

Note `MAILER_INBOUND_EMAIL_DOMAIN` is empty, so there is no `reply+<uuid>@` address as a
second threading path. Adding one needs an inbound-mail webhook (Postmark/Sendgrid/
Mailgun), not IMAP — not worth it while the flag covers it.

### `channel_aware_handoff_message.rb`

`handoff_message` is one string per **assistant**
(`enterprise/app/jobs/captain/conversation/response_builder_job.rb`, and again in
`enterprise/app/jobs/captain/inbox_pending_conversations_resolution_job.rb`). There is no
per-inbox override anywhere in 4.17.1 — Chatwoot has per-inbox greeting and out-of-office
text, but not this. So live chat got the email-shaped copy.

The patch prepends both call sites: WebWidget conversations use
`config['handoff_message_chat']` when set, every other channel falls through to upstream.
One assistant, one knowledge base. The alternative was a second assistant with its own
copy of 23 FAQs, 133 documents and 2 tools to keep in sync.

### Verifying and upgrading

These patches fail **silently**. If upstream renames a method the prepend still loads, the
override never fires, and behaviour quietly reverts to stock. So every patch has a check in
`deploy/scripts/verify_patches.rb`, and `make launch` runs it on every deploy. A patch with
no check is a patch that will rot.

Before bumping the image tag: `make snapshot`, `make backup`, diff the upstream files named
in each patch header against the new version, then `make launch` and read the verify output.

`channel_aware_handoff_message.rb` touches `enterprise/` code, which is under Chatwoot's
commercial licence. The licence covers modifications but still requires a paid licence in
production — see the open item.

## Why patches and not a forked image

We run the stock `chatwoot/chatwoot` image and overlay ~60 lines of Ruby. Building our fork
into an image instead means compiling Rails and Vue assets: the 2 GB VM cannot do it, an
Apple Silicon laptop has to cross-build for amd64, and Cloud Build turns a 40 second deploy
into a ~30 minute one. The fork checkout is still the reference tree — read real upstream
source there when writing a patch, and diff against it after an upgrade.

If a change ever outgrows what a `prepend` can express cleanly, that is the signal to
revisit this.

## Spam — there is no filter

Chatwoot has no spam handling. No scoring, no blocklist, no `Precedence: bulk` /
`Auto-Submitted` header check. Anything landing in the inbox becomes a conversation and
Barry replies to it.

Captain cannot be made to skip a message. The only gate is conversation status
(`return unless conversation.pending?` in
`enterprise/app/services/enterprise/message_templates/hook_execution_service.rb`) — nothing
inspects sender or content. And telling Barry to stay silent backfires: blank content raises
`ArgumentError` in `message_builder.rb`, which the error handler turns into a handoff message.

Silence only happens *before* a conversation reaches `pending`:

1. **Gmail filter** — mail Gmail files out of INBOX is never fetched. The IMAP service does
   `imap.select('INBOX')` and nothing else.
2. **Block the contact** — `conversation.rb` sets status `resolved` on create for a blocked
   contact, so it never becomes `pending`. Deterministic, and the cheapest reactive fix.
3. **Turn Captain off on the inbox** — nuclear.

Working approach: block junk senders as they appear, mark them spam in Gmail. Don't build
filtering ahead of actual spam.

---

## Common operations

From `~/Documents/chatwoot/deploy`:

```bash
make launch              # ship this folder, recreate rails + sidekiq, verify patches
make diff                # what the server has that the repo does not
make verify              # prove the patches are loaded (read-only, sends nothing)
make logs N=200          # tail rails + sidekiq
make console             # interactive rails console
make run FILE=scripts/x.rb   # run a local ruby script against production
make backup              # DB dump now
make snapshot            # disk snapshot now
make ssh                 # shell on the VM
```

`make launch` restarts the app containers, so chat and email are down for about
30 seconds. Postgres, Redis and Caddy are left running.

Raw equivalents, for when you are already on the box:

```bash
# ssh
gcloud compute ssh customer-service --project teeshirtpalacehosting --zone us-central1-a

# service state / logs
cd /opt/chatwoot && sudo docker compose ps
sudo docker compose logs rails --tail 50

# rails console
sudo docker compose exec rails bundle exec rails console

# run a script
sudo docker compose exec -T rails bundle exec rails runner - < script.rb

# manual backup
sudo /opt/chatwoot/backup.sh

# restore into a fresh box
sudo docker compose up -d postgres redis
sudo docker compose exec -T postgres psql -U postgres -c "CREATE DATABASE chatwoot_production;"
gzip -dc backup.sql.gz | sudo docker compose exec -T postgres psql -U postgres -d chatwoot_production -q
sudo docker compose up -d
```

The container image is Alpine — `bash` is not installed. Use `sh -lc` with
`docker compose exec`, and note its `grep` is busybox (no `--include`).

## Backups

1. **DB dump** — nightly cron 03:00, 7 days, on-box at `/opt/chatwoot/backups` (0700).
   Covers bad migrations and app-level mistakes.
2. **Disk snapshots** — GCE resource policy `chatwoot-daily`, daily 08:00 UTC, 14-day
   retention, attached to the boot disk. Covers disk/VM loss.

Both contain the order-status API key and the OpenAI key in plaintext. Treat as secrets.

`SECRET_KEY_BASE` must stay stable across deploys or all sessions break. Production secrets
are freshly generated and are **not** the ones from the local dev instance.

## Licensing and cost

Chatwoot's repo is split by directory. Everything outside `enterprise/` is MIT — inboxes,
conversations, email, contacts, automations, agent bots, the whole dashboard. Free forever,
unlimited seats. **Captain AI lives in `enterprise/`** and requires a paid license in
production. Forking does not change this; the enterprise license explicitly covers
modifications and patches.

| | 1 seat | 2 seats | 3 seats |
|---|---|---|---|
| Self-hosted Community (no Captain) | $0 | $0 | $0 |
| Self-hosted Premium (Captain AI) | $19/mo | $38/mo | $57/mo |

Paid self-hosted tiers are billed annually. Chatwoot cloud's Startups plan is the same
$19/agent but caps Captain at 300 credits/month, then $20/1,000. Self-hosting costs ~$15/mo
of GCP to get BYOK (uncapped AI at raw OpenAI token cost) and data on our own box.

**We have not bought a license yet.** The build ran under the enterprise license's
development-and-testing carve-out, which is fine for evaluation but not for answering real
customers.

## Open items

- [ ] **Buy the Chatwoot license** before this answers real customers
- [ ] **Rotate `CUSTOMER_SERVICE_ORDER_STATUS_API_KEY`** — short, guessable, plaintext in DB,
      internet-facing
- [ ] **Wire `support@printoracle.com`** — needs a real user mailbox (not a Google Group or
      alias — those can't do IMAP), 2-Step Verification on, an app password, and IMAP enabled
      in Gmail settings
- [x] **Auto-resolve tuning** — now `auto_resolve_mode=evaluated`, `auto_resolve_after=1440`
      (the 24h maximum; `MAXIMUM_INACTIVITY_THRESHOLD_MINUTES = 1.day.in_minutes`, so 3 days
      is not possible). Harmless either way: an incoming message reopens a resolved
      conversation.
- [ ] **Agent email signature** — `users.message_signature` is null. Per-agent, set in
      Profile Settings, toggled per channel type. No account-wide footer exists.
- [ ] **Business hours** on the inboxes (Mon-Fri 10-5 ET) so after-hours contact gets the
      out-of-office message. Now sharper than it was: chat's handoff promises "by the next
      business day" and nothing enforces that, so a Friday night chat is told something the
      inbox has no hours to back up.
- [ ] **Second inbox/assistant** for the other company
- [ ] **Commit `deploy/`** — the folder is untracked on `develop` in the fork. A
      `printoracle` branch would keep upstream merges clean.
- [ ] **Cost tuning** — `gpt-5.5` is the priciest tier ($5/$30 per 1M). `gpt-5.4` ($2.50/$15)
      and `gpt-5.4-mini` ($0.75/$4.50) are both registry-known; worth A/B-ing on the same
      question set before volume ramps.
