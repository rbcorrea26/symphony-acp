.PHONY: help all setup deps build fmt fmt-check lint test coverage ci dialyzer e2e cline-acp-e2e cline-deepseek-e2e

MIX ?= mix

help:
	@echo "Targets: setup, deps, fmt, fmt-check, lint, test, coverage, dialyzer, e2e, cline-acp-e2e, cline-deepseek-e2e, ci"

setup:
	$(MIX) setup

deps:
	$(MIX) deps.get

build:
	$(MIX) build

fmt:
	$(MIX) format

fmt-check:
	$(MIX) format --check-formatted

lint:
	$(MIX) lint

coverage:
	$(MIX) test --cover

test:
	$(MIX) test

dialyzer:
	$(MIX) deps.get
	$(MIX) dialyzer --format short

e2e:
	SYMPHONY_RUN_LIVE_E2E=1 $(MIX) test test/symphony_elixir/live_e2e_test.exs

cline-acp-e2e:
	SYMPHONY_RUN_CLINE_ACP_E2E=1 $(MIX) test test/symphony_elixir/cline_acp_e2e_test.exs

# Fase 5: o mesmo turno real, mas exigindo que o provedor usado seja o DeepSeek
# (o wrapper do pipeline entrega CLINE_PROVIDER/CLINE_MODEL/CLINE_API_KEY). Pago e
# opt-in: nunca roda em `make all`/CI. Uma execucao bem-sucedida e suficiente.
cline-deepseek-e2e:
	SYMPHONY_RUN_CLINE_DEEPSEEK_E2E=1 $(MIX) test test/symphony_elixir/cline_deepseek_e2e_test.exs

ci:
	$(MAKE) setup
	$(MAKE) build
	$(MAKE) fmt-check
	$(MAKE) lint
	$(MAKE) coverage
	$(MAKE) dialyzer

all: ci
