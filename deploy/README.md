# Print Oracle Chatwoot deployment

Everything the `customer-service` VM runs that is not the stock upstream image.
Edit here, commit, `make launch`. Do not edit files on the box.

```
deploy/
  Makefile               # the whole deploy
  docker-compose.yaml    # the 5 services, image pin, memory limits
  Caddyfile              # TLS + reverse proxy
  backup.sh              # nightly pg_dump, run by cron on the box
  patches/               # our Ruby changes, loaded as Rails initializers
  scripts/               # run locally against the server with `make run` (not deployed)
```

| command | what it does |
|---|---|
| `make launch` | ship this folder, recreate rails + sidekiq, verify patches, show status |
| `make diff` | every difference between this folder and the live server |
| `make verify` | prove the patches are loaded and behaving (read-only) |
| `make logs N=200` | tail rails + sidekiq |
| `make console` | interactive rails console on the server |
| `make run FILE=scripts/x.rb` | run a local ruby script against production |
| `make backup` / `make snapshot` | DB dump now / disk snapshot now |

`make launch` restarts the app containers, so chat and email are down for roughly
30 seconds. Postgres, Redis and Caddy are left alone.

## What is deliberately not here

- **`.env`** — secrets, lives only on the server at `/opt/chatwoot/.env`, mode 600.
  A deploy never reads or overwrites it. `SECRET_KEY_BASE` must stay stable or all
  sessions break.
- **`backups/`** — nightly dumps on the box.
- **Barry's configuration** — FAQs, guardrails, response guidelines, tools and the
  handoff copy live in Postgres, edited in the dashboard, not in this folder. A
  script that changes them belongs in `scripts/`.

## Why patches instead of a forked image

The patches are ~60 lines. Building this fork into an image means compiling Rails
and Vue assets: the 2 GB VM cannot do it, an Apple Silicon laptop has to cross-build
for amd64, and Cloud Build turns a 40 second deploy into a 30 minute one. The
overlay keeps deploys fast and keeps our diff against upstream tiny and readable.

The fork checkout above this folder is still the reference tree - read the real
upstream source there when writing a patch, and diff against it after an upgrade.

## Adding a patch

1. Read the upstream method you are changing in the fork checkout.
2. Add a file to `patches/`. Rails globs `config/initializers/**/*.rb`, so anything
   dropped in there loads on boot. Use `Rails.application.config.to_prepare` and
   `prepend` a module - never edit constants at load time.
3. Head the file with a comment naming the upstream file and method it overrides,
   and what upstream behaviour it is changing.
4. Add a check to `scripts/verify_patches.rb`. A patch with no check is a patch that
   will silently stop applying.
5. `make launch`.

Patches are mounted as a directory, not file by file. A file bind-mount keeps the
old inode when the file is replaced, so a deploy would ship a change the container
never sees.

## Current patches

| file | what upstream does | what we do |
|---|---|---|
| `imap_lock_to_single_conversation.rb` | `Imap::ImapMailbox#find_or_create_conversation` creates a new conversation for any mail without `In-Reply-To`/`References`, ignoring the inbox's `lock_to_single_conversation` flag | honour the flag, so a customer who composes a fresh email every time stays in one thread instead of spawning one per message |
| `channel_aware_handoff_message.rb` | one `handoff_message` per assistant, so live chat gets the email-shaped copy | WebWidget conversations use `config['handoff_message_chat']` when set; every other channel is untouched |

## Upgrading Chatwoot

Patches fail **silently** when upstream renames a method: the prepend still loads,
the override never fires, and behaviour quietly reverts. So:

1. `make snapshot` and `make backup`.
2. Bump the image tag in `docker-compose.yaml`.
3. Diff the upstream files named in each patch header against the new version.
4. `make launch` - it runs `make verify` for you and fails loudly if a patch stopped
   applying.

`enterprise/` code is under Chatwoot's commercial licence, which covers modifications
but still requires a paid licence in production. That is an open item.
