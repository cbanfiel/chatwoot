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
| Admin login | `chadbanfield@printoracle.com` (user id 2) |
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

Everything lives in `/opt/chatwoot`:

- `docker-compose.yaml` — 5 services: rails, sidekiq, postgres (pgvector/pg16), redis, caddy.
  Image pinned to `chatwoot/chatwoot:v4.17.1` (not `:latest` — upgrade deliberately, after a
  snapshot). Per-container `mem_limit` so Sidekiq can't starve Rails on a 2 GB box:
  rails 900m, sidekiq 700m, postgres 400m, redis 120m.
- `.env` — mode 600. `FRONTEND_URL`, `FORCE_SSL=true`, `ENABLE_ACCOUNT_SIGNUP=false`,
  `CAPTAIN_OPEN_AI_API_KEY` (our own OpenAI key), `CAPTAIN_OPEN_AI_MODEL=gpt-5.5`,
  `INSTALLATION_PRICING_PLAN=enterprise`.
- `Caddyfile` — `customer-service.printoracle.com { reverse_proxy rails:3000 }`
- `backup.sh` + `/etc/cron.d/chatwoot-backup` — nightly 03:00 `pg_dump`, 7-day retention.

Rails port 3000 is **not** published to the host; Caddy reaches it over the Docker network.
So `curl localhost:3000` on the VM fails by design — probe the public URL instead.

Do not add a `base:` service to the compose file. Chatwoot's published compose uses one as a
YAML anchor, which with `restart: always` becomes a container that restart-loops forever.
Our file uses a top-level `x-base: &base` extension field instead.

---

## How Barry is configured

Captain assistant "Barry", account "Print Oracle". Everything below is set in the dashboard
under Captain, no code.

- **7 FAQ snippets** ported from the Klaviyo agent — support hours, shipping/payment,
  order tracking, return policy, artwork requirements, TCHAT10 discount rule.
- **7 guardrails** — the handoff rules. See the gotcha below about why they're guardrails
  and not "Instructions".
- **6 response guidelines** — tone and format.
- **133 crawled pages** from printoracle.com, embedded with `text-embedding-3-small`.
  (Klaviyo's crawl of the same site failed; Chatwoot's succeeded.)
- **1 custom tool** — `print_oracle_order_status`, see below.
- **Handoff message** — "I am getting a teammate to help with this, they will reply here
  within 24-48 hrs."
- **Model** — `gpt-5.5`. Read the model gotcha before changing this.

Verified working: 8/8 handoff test matrix, live order lookup returning FedEx tracking,
correct inference on questions not explicitly covered (e.g. that an `.AI` file isn't on the
accepted-formats list).

## Inboxes

| id | name | channel | Barry on? |
|---|---|---|---|
| 1 | Support Test | Api | yes |
| 2 | Support | Email | yes |
| 3 | Website Chat | WebWidget | **no** — see below |

Inbox 3 was added 2026-09-08 to trial Chatwoot live chat as a Tawk.to replacement.
Widget token lives in this repo's `.env` as `NEXT_PUBLIC_CHATWOOT_TOKEN`; unset it and
`components/Chat.tsx` falls back to Tawk. Widget code: `components/ChatwootChat.tsx`.

Barry is deliberately **not** attached to inbox 3. His guardrails and handoff message are
email-shaped ("they will reply here within 24-48 hrs"), which reads wrong to someone sitting
in a live chat. Attach him only after writing chat-specific copy:

```ruby
CaptainInbox.create!(captain_assistant_id: 1, inbox_id: 3)
```

Anonymous web visitors have no email on the contact, so `print_oracle_order_status` gets an
empty `email` and 400s (same root cause as Captain gotcha 3). Logged-in visitors are fine —
the widget calls `$chatwoot.setUser` with the session email. For anonymous ones, either turn
on the inbox pre-chat form (asks for email before the first message) or let Barry ask.

## Integration with this repo

Barry calls one endpoint here:

```
GET /api/integrations/customer-service/order-status
    ?email={{customer_email}}&orderNumber={{order_number}}
Header: x-api-key: <CUSTOMER_SERVICE_ORDER_STATUS_API_KEY>
```

- Route: `app/api/integrations/customer-service/order-status/route.ts`
- Key: `CUSTOMER_SERVICE_ORDER_STATUS_API_KEY` in `.env`
- Timeout 10s, 2 retries, configured Chatwoot-side.

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
- [ ] **Auto-resolve tuning** — currently `auto_resolve_mode=evaluated` with the 60-minute
      default, too aggressive for email. Max allowed is 1440 minutes (24h);
      `MAXIMUM_INACTIVITY_THRESHOLD_MINUTES = 1.day.in_minutes`, so 3 days is not possible.
      Harmless either way: an incoming message reopens a resolved conversation.
- [ ] **Agent email signature** — `users.message_signature` is null. Per-agent, set in
      Profile Settings, toggled per channel type. No account-wide footer exists.
- [ ] **Business hours** on the inbox (Mon-Fri 10-5 ET) so after-hours mail gets the
      out-of-office message rather than the 24-48h promise
- [ ] **Second inbox/assistant** for the other company
- [ ] **Cost tuning** — `gpt-5.5` is the priciest tier ($5/$30 per 1M). `gpt-5.4` ($2.50/$15)
      and `gpt-5.4-mini` ($0.75/$4.50) are both registry-known; worth A/B-ing on the same
      question set before volume ramps.


---

## Follow-up context — 2026-09-08

The sections above were copied from `tsp-prints/docs/chatwoot.md` and include historical setup state. These later observations supersede conflicting details above:

- Live server inspection confirmed Barry is attached to all three inboxes, including Website Chat.
- The current handoff message is: "I'm getting a teammate to help with this. They'll reply right here, and you'll get an email too if you step away."
- Auto-resolution is now 1440 minutes; inactivity-resolution messages are disabled.
- The agent Instructions name was changed from Kai to Barry at the owner's request.
- Approved FAQ #8 was added and its embedding verified: at checkout, uncheck **Billing Address Same As Shipping** to enter a separate billing address. There are now eight approved FAQ entries.
- Audit covered 68 conversations / 159 messages. Only seven non-test conversations had public Captain replies. No other prompt changes were authorized or applied.

## Requested fork investigation — 2026-09-08

Scope: investigate (1) Email Id → Email Address and (2) an email blacklist with management UI. Silent handoffs are deferred. No application code or production configuration was changed during this investigation.

Repository: `cbanfiel/chatwoot`, inspected commit `b227f8042`. Its package version says 4.17.1, but this checkout was not verified to be the exact source behind the deployed v4.17.1 Docker image. Investigation worktree: `/Users/chadbanfield/Documents/chatwoot-support-audit`, branch `codex/support-audit`.

### 1. Email field label: existing configuration is sufficient

Settings → Inboxes → Website Chat → Pre Chat Form exposes a Label input for each enabled field. Set the `emailAddress` field label to `Email Address` and save. The widget renders that stored label directly. A fork/rebuild is unnecessary for the existing inbox.

Evidence:
- `app/javascript/dashboard/routes/dashboard/settings/inbox/PreChatForm/PreChatFields.vue`: editable `item.label` input.
- `app/javascript/dashboard/routes/dashboard/settings/inbox/PreChatForm/Settings.vue`: saves `channel.pre_chat_form_options.pre_chat_fields`.
- `app/models/channel/web_widget.rb`: permits label updates; default label is `Email Id`.
- `app/javascript/widget/components/PreChat/Form.vue`: `getLabel` returns the configured label.

### 2. Email blacklist: reuse contact blocking, but close delivery gaps

Existing UI already offers Contacts → contact → Block Contact / Unblock Contact, plus a Blocked contacts filter. Existing contact create/update APIs accept `blocked`; incoming email reuses account contacts by email. For exact addresses, a dedicated Blocked Emails screen could reuse this data and API rather than introduce a parallel blacklist table. This would retain account-wide contact-block semantics, not email-inbox-only blocking.

Blocking currently makes new conversations resolved and prevents incoming messages reopening resolved conversations. It does not provide a complete no-reply guarantee:
- The contact block action only updates the contact; it does not resolve an already-pending conversation.
- Captain scheduling/response eligibility uses conversation pending status without an explicit blocked-contact check.
- Greeting/out-of-office template hooks have no blocked-contact guard.
- The email send service has no blocked-contact guard, so existing/manual/queued outgoing messages need an explicit delivery policy.

Recommended first scope: exact email addresses, add/remove/list UI using existing contacts, retain incoming messages, suppress automated replies reliably. A strict prohibition on *all* outbound email also needs enforcement at delivery (including queued messages) and clear UI feedback rather than silently marking an unsent reply successful. Domain patterns and per-inbox rules would require additional scope; they were not implemented.

Evidence:
- `app/javascript/dashboard/components-next/Contacts/ContactsDetailsLayout.vue`
- `app/javascript/dashboard/routes/dashboard/contacts/contactFilterItems/index.js`
- `app/controllers/api/v1/accounts/contacts_controller.rb`
- `app/mailboxes/mailbox_helper.rb`, `app/builders/contact_inbox_with_contact_builder.rb`
- `app/models/conversation.rb#determine_conversation_status`, `app/models/message.rb#reopen_conversation`
- `app/services/message_templates/hook_execution_service.rb`
- `enterprise/app/services/enterprise/message_templates/hook_execution_service.rb`
- `enterprise/app/jobs/captain/conversation/response_builder_job.rb`
- `app/services/email/send_on_email_service.rb`

Validation was source inspection only. Before implementation, cover blocked new and existing conversations, queued replies, greeting/out-of-office messages, unblocking, and normal unblocked delivery. No live test messages were sent.


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

