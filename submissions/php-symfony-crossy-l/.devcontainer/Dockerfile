# Development container for this submission: the benchmark box's operating system, its Postgres 18 with
# the box's settings, and the toolchain install.sh installs. Build context is the repository root
# (see devcontainer.json), because install.sh and box/pg-conf.sh live there.
FROM mcr.microsoft.com/devcontainers/base:ubuntu-24.04@sha256:d94c97dd9cacf183d0a6fd12a8e87b526e9e928307674ae9c94139139c0c6eae

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8

# Tools the scripts under bench/ and the challenge's own scripts use.
RUN apt-get update \
 && apt-get install -y --no-install-recommends jq sysstat curl unzip util-linux rsync ca-certificates gnupg lsb-release \
 && rm -rf /var/lib/apt/lists/*

# PostgreSQL 18 from the PGDG apt repo, as box/setup-box.sh installs it, with the package Postgres recommends for JIT.
# Installed before install.sh so that libpq-dev resolves against the same repository as on the box.
RUN install -d /usr/share/keyrings \
 && curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc | gpg --dearmor --yes -o /usr/share/keyrings/pgdg.gpg \
 && echo "deb [signed-by=/usr/share/keyrings/pgdg.gpg] https://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" > /etc/apt/sources.list.d/pgdg.list \
 && apt-get update \
 && apt-get install -y --no-install-recommends postgresql-18 postgresql-client-18 postgresql-18-jit \
 && rm -rf /var/lib/apt/lists/*

# The toolchain: the submission's install.sh, on Ubuntu 24.04.
COPY submissions/php-symfony-crossy-l/install.sh /tmp/install.sh
RUN bash /tmp/install.sh && rm -rf /tmp/install.sh /var/lib/apt/lists/*

# Task, which runs the Taskfile in the submission folder.
ARG TASK_VERSION=3.54.0
ARG TASK_SHA256_AMD64=680859dbb4d881a9c72d4d9a8f510825450849af8567deacd7302c01124416fb
ARG TASK_SHA256_ARM64=d7189d439d4a6058e39e1b2acd7c8b27acd4856691b408f23b242e4294e1df5b
RUN arch="$(dpkg --print-architecture)" \
 && case "$arch" in amd64) sha="$TASK_SHA256_AMD64" ;; arm64) sha="$TASK_SHA256_ARM64" ;; *) echo "unsupported architecture $arch" >&2; exit 1 ;; esac \
 && curl -fsSLo /tmp/task.tgz "https://github.com/go-task/task/releases/download/v${TASK_VERSION}/task_linux_${arch}.tar.gz" \
 && echo "$sha  /tmp/task.tgz" | sha256sum -c --quiet - \
 && tar -C /usr/local/bin -xzf /tmp/task.tgz task \
 && rm /tmp/task.tgz \
 && task --version

# Go, which the challenge's own scripts build their tools with (the conformance suite, the load generator). The
# submission itself does not use it.
ARG GO_VERSION=1.27.3
ARG GO_SHA256_AMD64=65efbc80fdc1fa2cd2631cad5b481777a68e8725f34e89f50fc6ac714e379b40
ARG GO_SHA256_ARM64=a06e99309dbcbdca1a8ccd2282c3ee146e55930886e26b4f1193269587165f49
RUN arch="$(dpkg --print-architecture)" \
 && case "$arch" in amd64) sha="$GO_SHA256_AMD64" ;; arm64) sha="$GO_SHA256_ARM64" ;; *) echo "unsupported architecture $arch" >&2; exit 1 ;; esac \
 && curl -fsSLo /tmp/go.tgz "https://go.dev/dl/go${GO_VERSION}.linux-${arch}.tar.gz" \
 && echo "$sha  /tmp/go.tgz" | sha256sum -c --quiet - \
 && tar -C /usr/local -xzf /tmp/go.tgz \
 && rm /tmp/go.tgz \
 && ln -s /usr/local/go/bin/go /usr/local/bin/go \
 && ln -s /usr/local/go/bin/gofmt /usr/local/bin/gofmt \
 && go version

# The box's Postgres settings for its size (8 vCPU, 16 GB): localhost only, scram on 127.0.0.1, and
# box/pg-conf.sh run as if this machine were the box.
COPY box/pg-conf.sh /opt/box/pg-conf.sh
COPY submissions/php-symfony-crossy-l/.devcontainer/box-pg-conf.sh /opt/box/box-pg-conf.sh
RUN PGD=/etc/postgresql/18/main \
 && sed -ri "s/^#?listen_addresses\s*=.*/listen_addresses = 'localhost'/" "$PGD/postgresql.conf" \
 && (grep -q "^include_dir = 'conf.d'" "$PGD/postgresql.conf" || echo "include_dir = 'conf.d'" >> "$PGD/postgresql.conf") \
 && (grep -qE '^host\s+all\s+all\s+127\.0\.0\.1/32\s+scram-sha-256' "$PGD/pg_hba.conf" \
     || echo "host    all             all             127.0.0.1/32            scram-sha-256" >> "$PGD/pg_hba.conf") \
 && bash /opt/box/box-pg-conf.sh /opt/box/pg-conf.sh

# Starts the cluster and makes the roles. devcontainer.json runs it on every start.
COPY submissions/php-symfony-crossy-l/.devcontainer/devdb-up /usr/local/bin/devdb-up
RUN chmod 755 /usr/local/bin/devdb-up
