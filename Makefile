# Submodule directories (extracted from .gitmodules)
SUBMODULES := BioMate genomics-status StatusDB_NGI Yggdrasil demux_realm

help: ## Show this help
	@echo "Usage: make [target] [TARGET]"
	@echo ""
	@echo "All-submodule targets:"
	@echo "  init           Initialize and clone all submodules"
	@echo "  status         Show status of all submodules"
	@echo "  update-all     Pull latest from remote for all submodules"
	@echo "  sync           Sync submodules with .gitmodules remotes"
	@echo "  reset          Reset all submodules to their recorded commits"
	@echo "  use-dev        Switch all submodules to their 'dev' branches"
	@echo "  use-main       Switch all submodules to their 'main' branches"
	@echo "  extract-deps   Extract deps and show how to add them via pixi"
	@echo ""
	@echo "Compose targets (Yggdrasil workflow testing environment):"
	@echo "  compose-up                Build and start the stack (statusdb, biomate, yggdrasil)"
	@echo "  compose-up-full           Same as compose-up plus genomics-status (profile full)"
	@echo "  compose-up-statusdb       Build and start only statusdb"
	@echo "  compose-up-biomate        Build and start only biomate"
	@echo "  compose-up-yggdrasil      Build and start yggdrasil (plus its deps)"
	@echo "  compose-up-genomics-status  Build and start genomics-status (profile full)"
	@echo "  compose-down              Stop and remove the stack (volumes are kept)"
	@echo "  compose-logs              Follow yggdrasil logs"
	@echo "  compose-ps                Show stack status"
	@echo "  compose-reset             Stop the stack and remove all volumes"
	@echo "  compose-scenario          Inject a fresh test scenario into a running stack"
	@echo ""
	@echo "Per-submodule targets (replace TARGET with one of: $(SUBMODULES))"
	@echo "  update-TARGET  Pull latest for a single submodule"
	@echo "  status-TARGET  Show status for a single submodule"
	@echo "  sync-TARGET    Sync a single submodule's remote"
	@echo "  reset-TARGET   Reset a single submodule to recorded commit"
	@echo "  use-dev-TARGET Switch a single submodule to its 'dev' branch"
	@echo "  use-main-TARGET Switch a single submodule to its 'main' branch"

init:
	git submodule status --init > /dev/null 2>&1 || git submodule update --init --recursive

extract-deps:
	@DEPS=$$(python3 $(CURDIR)/extract_deps.py 2>&1); \
	ONELINES=$$(echo "$$DEPS" | head -1); \
	SPECIAL=$$(echo "$$DEPS" | tail -n +2); \
	echo "pixi add $$ONELINES"; \
	if [ -n "$$SPECIAL" ]; then \
		echo "─────────────────────────────────────────────────────────────────"; \
		echo "$$SPECIAL"; \
	fi

status:
	@git submodule status

sync:
	@git submodule sync

reset:
	@git submodule foreach 'git reset --hard @{u} && git clean -fd 2>/dev/null'

# Switch single submodule to dev
use-dev-%:
	@MODULE="$*"; \
	MODPATH=$$(git config --file .gitmodules submodule.$$MODULE.path 2>/dev/null); \
	if [ -z "$$MODPATH" ]; then \
		echo "Error: No submodule named '$$MODULE' found"; \
		exit 1; \
	fi; \
	IS_CLEAN=$$(cd "$$MODPATH" 2>/dev/null && git status --porcelain 2>/dev/null | wc -l); \
	if [ "$$IS_CLEAN" -gt 0 ]; then \
		echo "WARNING: $$MODULE has uncommitted changes, skipping"; \
		exit 1; \
	fi; \
	echo "Pulling latest for '$$MODULE' before checkout..."; \
	git -C "$$MODPATH" fetch --all 2>/dev/null; \
	echo "Switching '$$MODULE' to dev..."; \
	(cd $$MODPATH && git checkout dev 2>/dev/null) || \
		(IS_LOCAL=$$(cd $$MODPATH && git branch | grep -c 'dev' 2>/dev/null) && \
		if [ "$$IS_LOCAL" -gt 0 ]; then \
			(cd $$MODPATH && git checkout dev || git checkout -b dev --track origin/dev 2>/dev/null); \
		else \
			echo "WARNING: Dev branch 'dev' not found in '$$MODULE'"; \
			exit 1; \
		fi); \
	echo "Pulling latest..."; \
	git -C "$$MODPATH" pull --rebase; \
	git submodule update --recursive

# Switch single submodule to main (or master as fallback)
use-main-%:
	@MODULE="$*"; \
	MODPATH=$$(git config --file .gitmodules submodule.$$MODULE.path 2>/dev/null); \
	if [ -z "$$MODPATH" ]; then \
		echo "Error: No submodule named '$$MODULE' found"; \
		exit 1; \
	fi; \
	IS_CLEAN=$$(cd "$$MODPATH" 2>/dev/null && git status --porcelain 2>/dev/null | wc -l); \
	if [ "$$IS_CLEAN" -gt 0 ]; then \
		echo "WARNING: $$MODULE has uncommitted changes, skipping"; \
		exit 1; \
	fi; \
	BRANCH=$$(cd $$MODPATH && git branch -r --list 'origin/main' 2>/dev/null || true); \
	if echo "$$BRANCH" | grep -q 'main'; then \
		TARGET="main"; \
	else \
		TARGET="master"; \
		echo "No 'main' branch found for '$$MODULE', using 'master'"; \
	fi; \
	echo "Pulling latest for '$$MODULE' before checkout..."; \
	git -C "$$MODPATH" fetch --all 2>/dev/null; \
	echo "Switching '$$MODULE' to $$TARGET..."; \
	(cd $$MODPATH && git checkout $$TARGET 2>/dev/null) || \
		(IS_LOCAL=$$(cd $$MODPATH && git branch | grep -c "$$TARGET" 2>/dev/null) && \
		if [ "$$IS_LOCAL" -gt 0 ]; then \
			(cd $$MODPATH && git checkout $$TARGET || git checkout -b $$TARGET --track origin/$$TARGET 2>/dev/null); \
		else \
			echo "WARNING: Branch '$$TARGET' not found in '$$MODULE'"; \
			exit 1; \
		fi); \
	echo "Pulling latest..."; \
	git -C "$$MODPATH" pull --rebase; \
	git submodule update --recursive

# Switch all submodules to dev
use-dev:
	@for sub in $(SUBMODULES); do \
		MODPATH=$$(git config --file .gitmodules submodule.$$sub.path 2>/dev/null); \
		IS_CLEAN=$$(cd "$$MODPATH" 2>/dev/null && git status --porcelain 2>/dev/null | wc -l); \
		if [ "$$IS_CLEAN" -gt 0 ]; then \
			echo "WARNING: $$sub has uncommitted changes, skipping"; \
			continue; \
		fi; \
		echo "Pulling latest for '$$sub' before checkout..."; \
		git -C "$$MODPATH" fetch --all 2>/dev/null; \
		echo "Switching '$$sub' to dev..."; \
		(cd "$$MODPATH" && git checkout dev 2>/dev/null) || \
		(IS_LOCAL=$$(cd "$$MODPATH" && git branch | grep -c 'dev' 2>/dev/null) && \
			if [ "$$IS_LOCAL" -gt 0 ]; then \
				(cd "$$MODPATH" && git checkout dev || git checkout -b dev --track origin/dev 2>/dev/null); \
			else \
				echo "WARNING: Dev branch 'dev' not found in '$$sub'"; \
				continue; \
			fi); \
		echo "Pulling latest for '$$sub'..."; \
		git -C "$$MODPATH" pull --rebase; \
	done
	@echo "Syncing parent repo with updated submodule references"
	@git submodule sync

# Switch all submodules to main (or master as fallback)
use-main:
	@for sub in $(SUBMODULES); do \
		MODPATH=$$(git config --file .gitmodules submodule.$$sub.path 2>/dev/null); \
		IS_CLEAN=$$(cd "$$MODPATH" 2>/dev/null && git status --porcelain 2>/dev/null | wc -l); \
		if [ "$$IS_CLEAN" -gt 0 ]; then \
			echo "WARNING: $$sub has uncommitted changes, skipping"; \
			continue; \
		fi; \
		echo "Pulling latest for '$$sub' before checkout..."; \
		git -C "$$MODPATH" fetch --all 2>/dev/null; \
		BRANCH=$$(cd "$$MODPATH" && git branch -r --list 'origin/main' 2>/dev/null || true); \
		if echo "$$BRANCH" | grep -q 'main'; then \
			TARGET="main"; \
		else \
			TARGET="master"; \
			echo "No 'main' branch found for '$$sub', using 'master'"; \
		fi; \
		echo "Switching '$$sub' to $$TARGET..."; \
		(cd "$$MODPATH" && git checkout $$TARGET 2>/dev/null) || \
		(IS_LOCAL=$$(cd "$$MODPATH" && git branch | grep -c "$$TARGET" 2>/dev/null) && \
			if [ "$$IS_LOCAL" -gt 0 ]; then \
				(cd "$$MODPATH" && git checkout $$TARGET || git checkout -b $$TARGET --track origin/$$TARGET 2>/dev/null); \
			else \
				echo "WARNING: Branch '$$TARGET' not found in '$$sub'"; \
				continue; \
			fi); \
		echo "Pulling latest for '$$sub'..."; \
		git -C "$$MODPATH" pull --rebase; \
	done
	@echo "Syncing parent repo with updated submodule references"
	@git submodule sync

# Per-submodule status
status-%:
	@MODULE="$*"; \
	MODPATH=$$(git config --file .gitmodules submodule.$$MODULE.path 2>/dev/null); \
	if [ -z "$$MODPATH" ]; then \
		echo "Error: No submodule named '$$MODULE' found"; \
		exit 1; \
	fi; \
	git submodule status -- "$$MODPATH"

update-%:
	@MODULE="$*"; \
	MODPATH=$$(git config --file .gitmodules submodule.$$MODULE.path 2>/dev/null); \
	if [ -z "$$MODPATH" ]; then \
		echo "Error: No submodule named '$$MODULE' found"; \
		exit 1; \
	fi; \
	echo "Pulling latest for '$$MODULE' (branch: $$(cd $$MODPATH && git rev-parse --abbrev-ref HEAD))"; \
	git -C "$$MODPATH" pull --rebase; \
	git submodule update --recursive

update-all: init sync
	@for sub in $(SUBMODULES); do \
		MODPATH=$$(git config --file .gitmodules submodule.$$sub.path 2>/dev/null); \
		if [ -n "$$MODPATH" ]; then \
			BRANCH=$$(cd "$$MODPATH" && git rev-parse --abbrev-ref HEAD 2>/dev/null) || continue; \
			echo "Pulling latest for '$$sub' (branch: $$BRANCH)"; \
			git -C "$$MODPATH" pull --rebase origin $$BRANCH || echo "WARNING: Could not update $$sub"; \
		else \
			echo "WARNING: No .gitmodules entry for $$sub"; \
		fi; \
	done
	@echo "Syncing parent repo with updated submodule references"
	@cd "$(shell dirname $(lastword $(MAKEFILE_LIST)))" && git submodule sync

# ---------------------------------------------------------------------------
# Compose testing environment (Yggdrasil workflow)
# ---------------------------------------------------------------------------
COMPOSE := docker compose

compose-up: ## Build and start statusdb, biomate and yggdrasil
	$(COMPOSE) up -d --build

compose-build-gs-base: ## Build the genomics-status base image (conda env)
	docker build -q -t dataflow-genomics-status-base:latest ./genomics-status

compose-up-full: compose-build-gs-base ## compose-up plus genomics-status (profile "full")
	$(COMPOSE) --profile full up -d --build

# Per-service targets (mainly for testing). Compose also starts the
# depends_on closure of the requested service.
compose-up-statusdb: ## Build and start only statusdb
	$(COMPOSE) up -d --build statusdb

compose-up-biomate: ## Build and start only biomate
	$(COMPOSE) up -d --build biomate

compose-up-yggdrasil: ## Build and start yggdrasil (plus its deps: statusdb, biomate)
	$(COMPOSE) up -d --build yggdrasil

compose-up-genomics-status: compose-build-gs-base ## genomics-status (profile "full"; plus statusdb)
	$(COMPOSE) --profile full up -d --build genomics-status

compose-down: ## Stop and remove the stack (volumes are kept)
	$(COMPOSE) down --remove-orphans

compose-logs: ## Follow yggdrasil logs
	$(COMPOSE) logs -f yggdrasil

compose-ps: ## Show stack status
	$(COMPOSE) ps

compose-reset: ## Stop the stack and remove all volumes (fresh CouchDB on next up)
	$(COMPOSE) down -v --remove-orphans

compose-scenario: ## Inject a fresh test scenario into a running stack
	@curl -sf -X PUT \
		-u "$${STACK_COUCH_USER:-admin}:$${STACK_COUCH_PASSWORD:-secret}" \
		-H 'Content-Type: application/json' \
		--data-binary @deploy/seed/test_scenario_happy_path.json \
		"http://localhost:5984/yggdrasil/test_scenario:manual-$$(date +%s)" && \
		echo "Scenario injected; watch it with: make compose-logs"
