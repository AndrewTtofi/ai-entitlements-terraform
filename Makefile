.PHONY: install check validate summary fmt tf-test test lint lock

TF_DIRS = modules/entitlements modules/github-oidc-aws modules/github-oidc-gcp envs/example

install:
	pip install --require-hashes -r requirements-dev.txt

# Everything CI runs, without a tenant or a cloud account.
check: lint validate test tf-test

# The data file, in seconds, in plain words.
validate:
	python -m tools.validate

# Who gets what, as a table (CI puts this in the pull request).
summary:
	@python -m tools.validate --summary

fmt:
	terraform fmt -recursive
	ruff format tools tests && ruff check --fix tools tests

# The modules against mock providers: plan and apply with no credentials.
tf-test:
	terraform fmt -check -recursive
	@for dir in $(TF_DIRS); do \
	  echo "== $$dir"; \
	  terraform -chdir=$$dir init -backend=false -input=false > /dev/null || exit 1; \
	  terraform -chdir=$$dir validate -no-color > /dev/null || exit 1; \
	  terraform -chdir=$$dir test -no-color | tail -1 || exit 1; \
	done

test:
	pytest -q

lint:
	ruff check tools tests && ruff format --check tools tests && mypy tools

PIP_COMPILE = pip-compile --quiet --strip-extras --generate-hashes --allow-unsafe --no-emit-index-url
lock:
	$(PIP_COMPILE) $(ARGS) -o requirements-dev.txt requirements-dev.in
