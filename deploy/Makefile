# Print Oracle's Chatwoot deployment.
#
# Everything the server runs that is not the stock upstream image lives in this
# folder. Edit here, commit, then `make launch`. Nothing should be edited on the
# box directly - `make diff` will catch it if it was.

VM      ?= customer-service
PROJECT ?= teeshirtpalacehosting
ZONE    ?= us-central1-a
REMOTE  ?= /opt/chatwoot

# What gets shipped. .env and backups/ live only on the server and are never
# touched by a deploy.
PAYLOAD = Caddyfile backup.sh docker-compose.yaml patches

SSH = gcloud compute ssh $(VM) --project $(PROJECT) --zone $(ZONE) --command

.PHONY: help launch sync restart verify diff ps logs console run backup snapshot ssh

help:
	@grep -hE '^[a-z]+:.*##' $(MAKEFILE_LIST) | sed 's/:[^#]*## /~/' | awk -F'~' '{printf "  \033[1m%-10s\033[0m %s\n", $$1, $$2}'

launch: sync restart verify ps ## deploy this folder and recreate rails + sidekiq (about 30s downtime)

sync: ## copy config + patches to the server, nothing else
	COPYFILE_DISABLE=1 tar --no-xattrs -czf - $(PAYLOAD) | $(SSH) 'sudo tar xzf - -C $(REMOTE) && sudo chmod 700 $(REMOTE)/backup.sh && \
	  sudo find $(REMOTE) -name "._*" -delete'

restart: ## recreate the app containers so initializers reload
	$(SSH) 'cd $(REMOTE) && sudo docker compose up -d --force-recreate rails sidekiq'

verify: ## prove every patch is loaded and behaving (read-only, sends nothing)
	@$(MAKE) run FILE=scripts/verify_patches.rb

diff: ## show every difference between this folder and the live server
	@COPYFILE_DISABLE=1 tar --no-xattrs -czf - $(PAYLOAD) | $(SSH) 'rm -rf /tmp/cw-deploy && mkdir -p /tmp/cw-deploy && tar xzf - -C /tmp/cw-deploy && \
	  sudo diff -ru --exclude=.env --exclude=backups --exclude="*.bak" --exclude="*.sql.gz" $(REMOTE) /tmp/cw-deploy' \
	  && echo "server matches this folder"

ps: ## container status
	@$(SSH) 'cd $(REMOTE) && sudo docker compose ps --format "table {{.Service}}\t{{.Status}}"'

logs: ## tail app logs, e.g. make logs N=200
	$(SSH) 'cd $(REMOTE) && sudo docker compose logs rails sidekiq --tail $(or $(N),80)'

console: ## interactive rails console on the server
	gcloud compute ssh $(VM) --project $(PROJECT) --zone $(ZONE) -- -t 'cd $(REMOTE) && sudo docker compose exec rails bundle exec rails console'

run: ## run a local ruby script against the server, e.g. make run FILE=scripts/foo.rb
	@test -n "$(FILE)" || { echo "usage: make run FILE=path/to/script.rb"; exit 1; }
	$(SSH) 'cd $(REMOTE) && sudo docker compose exec -T rails bundle exec rails runner -' < $(FILE)

backup: ## run the nightly DB dump right now
	$(SSH) 'sudo $(REMOTE)/backup.sh && sudo ls -lh $(REMOTE)/backups | tail -3'

snapshot: ## disk snapshot before an upgrade or anything scary
	gcloud compute disks snapshot $(VM) --project $(PROJECT) --zone $(ZONE) \
	  --snapshot-names=$(VM)-manual-$$(date +%Y%m%d-%H%M%S)

ssh: ## shell on the VM
	gcloud compute ssh $(VM) --project $(PROJECT) --zone $(ZONE)
