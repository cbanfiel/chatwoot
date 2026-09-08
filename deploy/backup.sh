#!/usr/bin/env bash
# Nightly Chatwoot DB dump. Keeps 7 days. Contains secrets - dir is root-only 0700.
set -euo pipefail
cd /opt/chatwoot
STAMP=$(date +%Y%m%d-%H%M%S)
docker compose exec -T postgres pg_dump -U postgres --no-owner --no-acl chatwoot_production \
  | gzip > "/opt/chatwoot/backups/chatwoot-${STAMP}.sql.gz"
find /opt/chatwoot/backups -name "chatwoot-*.sql.gz" -mtime +7 -delete
