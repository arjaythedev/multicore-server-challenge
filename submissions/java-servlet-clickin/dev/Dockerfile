# Local Linux box for conformance and load checks (not used by the benchmark).
#   docker build -t conduit-box submissions/java-servlet-clickin/dev
#   docker run -d --name cbox --cpus 8 --shm-size 1g -v "$PWD":/repo conduit-box
FROM ubuntu:24.04
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y -q curl ca-certificates gnupg lsb-release jq git sudo build-essential procps \
 && curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc | gpg --dearmor -o /usr/share/keyrings/pgdg.gpg \
 && echo "deb [signed-by=/usr/share/keyrings/pgdg.gpg] https://apt.postgresql.org/pub/repos/apt noble-pgdg main" > /etc/apt/sources.list.d/pgdg.list \
 && apt-get update && apt-get install -y -q postgresql-18 postgresql-client-18 && rm -rf /var/lib/apt/lists/*
RUN ARCH=$(dpkg --print-architecture) \
 && GOV=$(curl -fsSL 'https://go.dev/dl/?mode=json' | jq -r '.[0].version') \
 && curl -fsSL "https://go.dev/dl/${GOV}.linux-${ARCH}.tar.gz" | tar -C /usr/local -xz
ENV PATH=/usr/local/go/bin:$PATH
RUN PGD=/etc/postgresql/18/main \
 && sed -ri "s/^#?listen_addresses\s*=.*/listen_addresses = 'localhost'/" $PGD/postgresql.conf \
 && echo "host all all 127.0.0.1/32 scram-sha-256" >> $PGD/pg_hba.conf \
 && printf "max_connections = 100\nshared_buffers = 1GB\nwork_mem = 4MB\nmax_wal_size = 4GB\njit = off\n" > $PGD/conf.d/90-local.conf
COPY entry.sh /entry.sh
CMD ["bash", "/entry.sh"]
