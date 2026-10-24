# source this, then run lab/capacity.sh / lab/bench.sh from the repo root (.tmp/multicore-server-challenge)
export PATH=/home/luben/code/UC/.tmp/mcsc-help/go/bin:$PATH GOTOOLCHAIN=local GOPATH=/home/luben/code/UC/.tmp/mcsc-help/gopath GOCACHE=/home/luben/code/UC/.tmp/mcsc-help/gocache
export PGHOST=127.0.0.1 PGPORT=55432 PGUSER=postgres
export PG_CGROUP=/sys/fs/cgroup/system.slice/docker-$(docker inspect -f '{{.Id}}' mcsc-pg).scope
export SRV_CPUS=0-7 LG_CPUS=8-19 LOADGEN=/home/luben/code/UC/.tmp/mcsc-help/bin/loadgen
export JAVA_HOME=/home/luben/code/UC/.tmp/mcsc-help/jdk27
export GRADLE_USER_HOME=/home/luben/code/UC/.tmp/mcsc-help/gradle-home KONAN_DATA_DIR=/home/luben/code/UC/.tmp/mcsc-help/konan
