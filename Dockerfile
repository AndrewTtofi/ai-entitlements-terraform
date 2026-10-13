# Everything `make check` needs, in one image: Python, the validator's dependencies, a
# pinned Terraform and the providers. No Okta tenant, no cloud account, no credentials.
FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1 \
    TF_IN_AUTOMATION=1 \
    # Terraform phones home for version checks otherwise.
    CHECKPOINT_DISABLE=1

RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl make unzip \
 && rm -rf /var/lib/apt/lists/*

# The same pinned, checksum-verified Terraform that CI installs, from the same script.
COPY .terraform-version scripts/install_terraform.sh /tmp/
RUN TERRAFORM_BIN=/usr/local/bin /tmp/install_terraform.sh "$(cat /tmp/.terraform-version)"

WORKDIR /srv
# Dependencies first, from the hashed lockfile, so this layer is cached between builds.
COPY requirements-dev.txt .
RUN pip install --no-cache-dir --require-hashes -r requirements-dev.txt

# Not root: nothing here needs it.
RUN useradd --create-home --uid 1000 check \
 && mkdir -p /opt/terraform-providers && chown check /srv /opt/terraform-providers
COPY --chown=check . .
USER check

# The providers, at the versions in the committed lock files, copied into the image as a
# local mirror. A plugin cache would not do: `terraform init` still asks the registry
# which versions exist. With a mirror as the only source, a run needs no network.
RUN for dir in modules/entitlements modules/github-oidc-aws modules/github-oidc-gcp envs/example; do \
      terraform -chdir="$dir" init -backend=false -input=false > /dev/null \
        && terraform -chdir="$dir" providers mirror /opt/terraform-providers > /dev/null || exit 1; \
    done \
 # The working copies `init` made are the same files again: keep the mirror only.
 && find . -type d -name .terraform -prune -exec rm -rf {} + \
 && printf 'provider_installation {\n  filesystem_mirror {\n    path = "/opt/terraform-providers"\n  }\n}\n' > /home/check/.terraformrc

CMD ["make", "check"]
