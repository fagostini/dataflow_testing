# dataflow_testing

A testing environment for the **Yggdrasil** workflow. It wires the
submodules in this repository into a single Docker Compose stack, starts
Yggdrasil only after its dependencies are up and running, and (by default)
fires an end-to-end test scenario so you can see the whole event-driven
pipeline work: CouchDB change → plan generation → plan persistence → plan
execution → event/ops artifacts.

```
                    ┌────────────────────────── compose network ──────────────────────────┐
                    │                                                                      │
  :5984 ───────────►│ statusdb      CouchDB 3.4, seeds projects/gs_users/... on first boot │
                    │        ▲                                                             │
                    │        │ http://statusdb:5984                                        │
  :8765 ───────────►│ biomate     BioMate web interface                                    │
                    │                                                                      │
  :9761 ───────────►│ genomics-status  (only with --profile full)                          │
                    │        ▲                                                             │
                    │        │ (stub config → statusdb)                                    │
                    │  ┌────────────────────────────────────────────────────────────────┐  │
                    │  │ yggdrasil daemon (yggdrasil --dev daemon)                      │  │
                    │  │ depends_on: statusdb + biomate healthy                         │  │
                    │  │ entrypoint: wait CouchDB → wait seeded DBs → create ygg DBs    │  │
                    │  │            → inject test scenario → start daemon               │  │
                    │  └────────────────────────────────────────────────────────────────┘  │
                    └──────────────────────────────────────────────────────────────────────┘
```

## Repository layout

```
├── docker-compose.yml           # the stack (statusdb, biomate, yggdrasil, genomics-status)
├── deploy/
│   ├── Dockerfile.yggdrasil     # Yggdrasil daemon image (no Dockerfile in the submodule)
│   ├── yggdrasil-entrypoint.sh  # readiness gate + DB bootstrap + scenario injection
│   ├── yggdrasil-config/main.json
│   ├── seed/test_scenario_happy_path.json
│   ├── Dockerfile.genomics-status   # builds on top of the submodule's conda-env image
│   └── genomics-status/             # stub settings/credentials for the full stack
├── Makefile                     # submodule management + compose-* targets
├── pyproject.toml / pixi.lock   # pixi workspace aggregating submodule deps
├── extract_deps.py / get_deps.sh
├── BioMate/                     # submodule
├── demux_realm/                 # submodule (Yggdrasil realm dmx_realm, installed in the Yggdrasil image)
├── genomics-status/             # submodule
├── StatusDB_NGI/                # submodule
└── Yggdrasil/                   # submodule
```

The submodules are never modified by this repository: images are built from
their Dockerfiles (or, for Yggdrasil, from a Dockerfile in `deploy/`), and all
runtime configuration is baked into images rather than written into submodule
working trees.

## Prerequisites

- Docker Engine with the Compose plugin (v2+). Tested with Docker 29.8 and
  Compose v5.5.
- git (submodules)
- Optional: [pixi](https://pixi.sh), only for the
  [submodule dependency workflow](#submodule-dependency-workflow).

First-time builds pull base images and install dependencies, so expect a
several-minute build. Subsequent builds are fast (layer caching).

## Quickstart

```bash
git clone git@github.com:fagostini/dataflow_testing.git
cd dataflow_testing
make init            # clone/update the submodules
make compose-up      # build + start statusdb, biomate, yggdrasil
```

That's it. What happens automatically:

1. `statusdb` starts CouchDB and (on a fresh volume) seeds the `projects`,
   `gs_users`, `gs_configs`, `server_status` databases in the background.
2. `biomate` serves its web interface on port 8765.
3. `yggdrasil` starts only after `statusdb` **and** `biomate` report healthy
   (`depends_on: condition: service_healthy`), then its entrypoint:
   - waits until CouchDB answers `/_up` **and** the seeded `projects` DB
     exists (CouchDB being "up" is not enough — the seed runs afterwards),
   - creates the `yggdrasil`, `yggdrasil_plans`, `yggdrasil_ops` databases
     (Yggdrasil fails fast at startup if any of its databases are missing),
   - injects a `happy_path` test scenario document (skip with
     `YGG_INJECT_TEST_SCENARIO=false`),
   - starts `yggdrasil --dev daemon` (`--dev` enables the built-in
     `test_realm` used for testing).
4. The daemon replays the changes feed from the beginning, picks up the
   scenario, generates a plan from the `happy_path` recipe, persists it to
   `yggdrasil_plans`, executes it via the Engine, and writes `plan_status`
   documents to `yggdrasil_ops`. Step artifacts land in the `ygg-work` and
   `ygg-events` volumes.

### Verify it worked

```bash
make compose-ps          # all services "healthy", yggdrasil "Up"
make compose-logs        # follow the daemon
```

Expected log lines:

```
Generating plan from recipe 'happy_path' for scenario 'test_scenario:compose-demo'
Persisted plan 'test_realm:test_scenario:compose-demo' to yggdrasil_plans
Eligible plan detected: test_realm:test_scenario:compose-demo (authority=daemon, ...)
Executing plan ...
✓ Plan 'test_realm:test_scenario:compose-demo' execution completed
```

And from the host:

```bash
# the executed plan document
curl -s -u "$STACK_COUCH_USER:$STACK_COUCH_PASSWORD" \
  "http://localhost:5984/yggdrasil_plans/_all_docs?include_docs=true"

# step artifacts and the event spool
docker compose exec yggdrasil find /work /events -type f
```

UIs on the host:

| Port | Service |
|------|---------|
| 5984 | CouchDB (StatusDB) — `_all_docs`, `_changes`, etc. |
| 8765 | BioMate web interface |
| 9761 | Genomics Status (only in the `full` profile) |

## Firing more work

The daemon stays running and watches CouchDB, so you can inject more scenarios
any time:

```bash
make compose-scenario   # PUTs a fresh test_scenario:manual-<timestamp> doc
```

The running daemon picks it up within a few seconds (watch `make compose-logs`).
Each injection gets a unique document id, so it always executes; the initial
`test_scenario:compose-demo` is injected only once and is **not** re-executed
on restarts (plans are tracked by `run_token`/`executed_run_token` and
watcher checkpoints are persisted in CouchDB). Use `make compose-reset` for a
completely fresh state.

### Test recipes

Scenario documents select a recipe via the `recipe` field
(`deploy/seed/test_scenario_happy_path.json` is the template; change `recipe`
and `PUT` to `http://localhost:5984/yggdrasil/<your-id>`):

| Recipe | Behaviour |
|--------|-----------|
| `happy_path` | all steps succeed (echo → sleep → echo) |
| `fail_fast` | first step fails |
| `fail_mid_plan` | fails partway through execution |
| `long_running` | extended sleep (timeout testing) |
| `artifact_write` | tests artifact registration |

## Full stack (genomics-status)

```bash
make compose-up-full    # compose-up plus genomics-status (profile "full")
```

`genomics-status` is opt-in because it is the heaviest service: the submodule
Dockerfile only installs the conda environment, so `deploy/Dockerfile.genomics-status`
builds on top of it and bakes in the app source plus stub configuration
(`deploy/genomics-status/`: `settings.yaml`, `.genologicsrc`, `.genosqlrc.yaml`,
`lims_backend_cred.yaml`, `orderportal_cred.yaml`). The stubs point LIMS /
order portal / Zendesk / Jira / Slack at mock URLs, and the app runs with
`--testing_mode` (no Google auth). It talks to the real `statusdb` CouchDB.

In the full stack, the yggdrasil entrypoint additionally waits for
`genomics-status:9761` before starting the daemon (it can't be a compose
`depends_on` because profile-gated services can't be static dependencies).

## Configuration

Copy `.env.example` to `.env` to override any of these (the stack runs with
the defaults otherwise):

| Variable | Default | Purpose |
|----------|---------|---------|
| `STACK_COUCH_USER` | `admin` | CouchDB admin user for the stack. The `STACK_` prefix deliberately avoids colliding with `COUCHDB_USER` that may exist in your shell for other purposes. |
| `STACK_COUCH_PASSWORD` | `secret` | CouchDB admin password. |
| `HOST_UID` / `HOST_GID` | `1000` | User the biomate container runs as (upstream convention). |
| `YGG_INJECT_TEST_SCENARIO` | `true` | Inject the happy_path scenario on container start. |
| `YGG_SCENARIO_ID` | `test_scenario:compose-demo` | Document id of the injected scenario. |

Where things live:

- **Yggdrasil config**: `deploy/yggdrasil-config/main.json` (CouchDB endpoint,
  connections `projects_db` / `yggdrasil_db` / `yggdrasil_testdocs` /
  `demux_sample_info_db` / `flowcell_status_db`, poll
  intervals). Baked into the image at the path Yggdrasil's `ConfigLoader`
  expects. If you change it, rebuild: `make compose-up`.
- **Genomics Status stubs**: `deploy/genomics-status/` (baked in the same way).
  Note the CouchDB credentials are hardcoded to the defaults there — if you
  change `STACK_COUCH_*`, update `deploy/genomics-status/settings.yaml` too.
- **Volumes**: `couchdb-data` (CouchDB, incl. seed marker and Yggdrasil
  state), `ygg-work` (plan step artifacts), `ygg-events` (event JSON spool),
  `ygg-logs` (daemon log files).

## How it works (short version)

```
scenario doc (type=ygg_test_scenario) in the `yggdrasil` DB
  → WatcherManager (CouchDB changes feed, replays from start_seq=0)
  → test_realm handler generates a plan from the recipe
  → plan persisted to `yggdrasil_plans` (auto_run ⇒ approved)
  → PlanWatcher emits PLAN_EXECUTION
  → Engine executes the steps (work under YGG_WORK_ROOT=/work)
  → step events spooled to YGG_EVENT_SPOOL=/events
  → OpsConsumerService writes plan_status to `yggdrasil_ops`
```

Only `test_realm` is registered in this environment (it is the dev-only
testing realm; the production `smartseq3`/`tenx` realms are not part of the
test stack).

## Submodule dependency workflow

This repository doubles as a pixi workspace that aggregates the Python
dependencies of all submodules (see `pyproject.toml` / `pixi.lock`). Useful
targets:

| Target | Purpose |
|--------|---------|
| `make init` | Clone/update all submodules |
| `make status` / `make status-<TARGET>` | Show submodule state |
| `make update-<TARGET>` / `make update-all` | Pull latest for one/all submodules |
| `make use-dev` / `make use-dev-<TARGET>` | Switch to `dev` branches |
| `make use-main` / `make use-main-<TARGET>` | Switch to `main`/`master` branches |
| `make sync` | Sync submodule remotes with `.gitmodules` |
| `make reset` | Reset submodules to their recorded commits |
| `make extract-deps` | Print a `pixi add ...` one-liner from the submodules' `pyproject.toml` files |

After updating submodules, `make compose-up` rebuilds the images from the new
code. For genomics-status, the base (conda env) image is rebuilt automatically
by `compose-up-full`.

## Makefile reference (compose)

| Target | Purpose |
|--------|---------|
| `make compose-up` | Build + start statusdb, biomate, yggdrasil |
| `make compose-up-full` | Same, plus genomics-status (profile `full`) |
| `make compose-up-statusdb` | Build + start only statusdb |
| `make compose-up-biomate` | Build + start only biomate |
| `make compose-up-yggdrasil` | Build + start yggdrasil (also starts its deps: statusdb, biomate) |
| `make compose-up-genomics-status` | Build + start genomics-status (profile `full`; also starts statusdb) |
| `make compose-build-gs-base` | Build only the genomics-status base image (conda env) |
| `make compose-logs` | Follow yggdrasil logs |
| `make compose-ps` | Stack status |
| `make compose-scenario` | Inject a fresh test scenario into the running stack |
| `make compose-down` | Stop the stack (volumes kept) |
| `make compose-reset` | Stop the stack and remove all volumes (fresh CouchDB/plan state) |

## Troubleshooting

- **`Network … Resource is still in use`** (on `down`) or
  **`failed to set up container networking: network … not found`** (on `up`)
  — a profile-gated container (e.g. `genomics-status` from a previous
  `compose-up-full`) was left behind by a default-profile `down`, keeping the
  shared project network alive (or stranding the container without it).
  `make compose-down` / `make compose-reset` now pass `--profile full` and
  cover all services; if you hit this with an older checkout, run
  `docker compose --profile full down --remove-orphans` once, then
  `make compose-up` / `make compose-up-full`.
- **Port already in use (5984/8765/9761)** — something else is bound to the
  host port. Change the host-side port in `docker-compose.yml` (left of the
  colon) or stop the conflicting process.
- **yggdrasil stuck at "Waiting for CouchDB"** — check
  `docker compose ps` for statusdb health. Credentials are taken from
  `STACK_COUCH_USER`/`STACK_COUCH_PASSWORD` and mirrored into the yggdrasil
  container as `YGG_COUCH_USER`/`YGG_COUCH_PASS`; if you changed one side only,
  they no longer match.
- **Stale plans/scenarios from earlier runs** — `make compose-reset` wipes the
  CouchDB volume (and all Yggdrasil state); the next `up` re-seeds.
- **`Configuration file 'module_registry.json' not found` in the logs** — the
  yggdrasil image is older than the current setup; rebuild with
  `make compose-up`.
- **Genomics Status 500s on `/`** — its stub config is baked into the image;
  after editing anything under `deploy/genomics-status/`, rebuild with
  `make compose-up-full`.
- **Submodules have uncommitted local changes** — the `use-*`/`update-*`/
  `reset` targets refuse to touch dirty submodules (by design). The compose
  stack never writes into submodule trees, so any dirt there came from manual
  edits.

## Submodule provenance

| Submodule | Upstream | Role in the stack |
|-----------|----------|-------------------|
| `StatusDB_NGI` | [NationalGenomicsInfrastructure/StatusDB_NGI](https://github.com/NationalGenomicsInfrastructure/StatusDB_NGI) | CouchDB image + seed data (`statusdb`) |
| `Yggdrasil` | [NationalGenomicsInfrastructure/Yggdrasil](https://github.com/NationalGenomicsInfrastructure/Yggdrasil) | The orchestration daemon under test |
| `demux_realm` | [NationalGenomicsInfrastructure/demux_realm](https://github.com/NationalGenomicsInfrastructure/demux_realm) | Yggdrasil realm for demux planning; installed into the Yggdrasil image as realm `dmx_realm` (`--no-deps`), watches the `demux_sample_info` + `flowcell_status` DBs (bootstrapped by the yggdrasil entrypoint). **Requires the Yggdrasil `dev` branch** (handler API `generate_plan_drafts`) |
| `BioMate` | [fagostini/BioMate](https://github.com/fagostini/BioMate) | Bio-data tooling + web interface (`biomate`) |
| `genomics-status` | [fagostini/genomics-status](https://github.com/fagostini/genomics-status) | Status dashboard UI (`genomics-status`, profile `full`) |