# Claude Code on Gemini Enterprise — Phase 0 skeleton
# Re-read CLAUDE.md before changing this file.

SHELL := /usr/bin/env bash
.SHELLFLAGS := -eu -o pipefail -c

PROJECT_ID    ?= cpe-slarbi-nvd-ant-demos
REGION        ?= us-central1
STATE_BUCKET  ?= $(PROJECT_ID)-tfstate

BOOTSTRAP_DIR := infra/terraform/bootstrap
MAIN_TF_DIR   := infra/terraform

.PHONY: help check-env bootstrap deploy smoke sandbox-smoke iso-test \
        register-agent register-agent-apply unregister-agent cuj-test \
        lint github-init

help:
	@echo "Targets:"
	@echo "  check-env             Verify gcloud/terraform/gh/jq/ruff and project context"
	@echo "  bootstrap             terraform apply infra/terraform/bootstrap"
	@echo "  smoke                 Phase 5+6 end-to-end smoke (Cloud Run bridge + park/restore)"
	@echo "  sandbox-smoke         Phase 4 in-cluster smoke (multi-turn across pod restart)"
	@echo "  iso-test              Phase 6 negative isolation test"
	@echo "  register-agent        Phase 7: dry-run registration (prints payload, no API call)"
	@echo "  register-agent-apply  Phase 7: POST/PATCH the registration to Discovery Engine"
	@echo "  unregister-agent      Phase 7: DELETE the registered agent (--apply via script)"
	@echo "  cuj-test              Phase 7: non-interactive sanity check on the registered agent"
	@echo "  lint                  ruff check + py_compile + terraform fmt -check"
	@echo "  github-init           [deferred per Phase 0 lock — do not run yet]"

check-env:
	@scripts/check-env.sh

bootstrap: check-env
	cd $(BOOTSTRAP_DIR) && terraform init && terraform apply -auto-approve \
	  -var "project_id=$(PROJECT_ID)" \
	  -var "region=$(REGION)" \
	  -var "state_bucket_name=$(STATE_BUCKET)"

deploy:
	@echo "deploy: not yet implemented — Phase 1+"; exit 1

smoke:
	@scripts/smoke.sh

sandbox-smoke: check-env
	@scripts/sandbox-smoke.sh

iso-test:
	@scripts/iso-test.sh

register-agent:
	@scripts/register-agent.sh

register-agent-apply:
	@scripts/register-agent.sh --apply

unregister-agent:
	@scripts/unregister-agent.sh --apply

cuj-test:
	@scripts/cuj-test.sh

lint:
	ruff check .
	@PYFILES=$$(find bridge backend scripts -name '*.py' 2>/dev/null || true); \
	 if [ -n "$$PYFILES" ]; then echo "$$PYFILES" | xargs python3 -m py_compile; \
	 else echo "lint: no python files yet"; fi
	terraform -chdir=$(BOOTSTRAP_DIR) fmt -check
	@if ls $(MAIN_TF_DIR)/*.tf >/dev/null 2>&1; then \
	   terraform -chdir=$(MAIN_TF_DIR) fmt -check ; \
	 fi

github-init:
	@echo "github-init: deferred per Phase 0 lock — do not run yet"; exit 1
