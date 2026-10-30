#!/usr/bin/env python3
"""Guarded full-seed load search for this workstation; never an official score.

Reflinks the existing stopped PG volume into a disposable volume. Owns only its
temporary Docker assets and systemd units. App+loadgen: 4 CPUs/2 GiB; PG: 4 CPUs/8 GiB, bounded
disk I/O. An independent watchdog stops the test on host resource pressure.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import threading
import time

HERE = Path(__file__).resolve().parents[1]
IMAGE = "postgres@sha256:edb0c08dc33befd0262ab3b5cf1c4f3f8cfd8b09e88c05b45adee29d6761ddb6"
ORIGINAL = "nouredeen-challenge-pg18"
GIB = 1024**3


def command(*args, timeout=30, check=True):
    return subprocess.run(args, capture_output=True, text=True, timeout=timeout, check=check)


def number(path):
    return int(Path(path).read_text().strip())


def cgroup_for_pid(pid):
    line = next(s for s in Path(f"/proc/{pid}/cgroup").read_text().splitlines() if s.startswith("0::"))
    return Path("/sys/fs/cgroup" + line[3:])


def host_sample():
    mem = dict(line.split(":", 1) for line in Path("/proc/meminfo").read_text().splitlines())
    result = {"time": time.time(), "available_gib": int(mem["MemAvailable"].split()[0]) * 1024 / GIB}
    for kind in ("cpu", "memory", "io"):
        for line in Path(f"/proc/pressure/{kind}").read_text().splitlines():
            fields = line.split()
            result[kind + "_" + fields[0]] = float(fields[1].split("=")[1])
    temps = []
    for zone in Path("/sys/class/thermal").glob("thermal_zone*"):
        if (zone / "type").read_text().strip() == "x86_pkg_temp":
            temps.append(number(zone / "temp") / 1000)
    result["cpu_temp_c"] = max(temps) if temps else None
    result["disk_busy_ms"] = int(Path("/sys/class/block/nvme0n1/stat").read_text().split()[9])
    result["nvme_composite_c"] = None
    result["nvme_stop_c"] = None
    for hwmon in Path("/sys/class/hwmon").glob("hwmon*"):
        if (hwmon / "name").read_text().strip() == "nvme":
            current = number(hwmon / "temp1_input") / 1000
            limit = min(number(hwmon / "temp1_max"), number(hwmon / "temp1_crit")) / 1000 - 1
            if result["nvme_composite_c"] is None or current - limit > result["nvme_composite_c"] - result["nvme_stop_c"]:
                result["nvme_composite_c"], result["nvme_stop_c"] = current, limit
    return result


def group_sample(path):
    if path is None or not path.exists():
        return None
    try:
        stats = dict((k, int(v)) for k, v in (s.split() for s in (path / "memory.stat").read_text().splitlines()))
        return dict(memory=number(path / "memory.current"), peak=number(path / "memory.peak"),
                    nonreclaimable=sum(stats.get(k, 0) for k in ("anon", "shmem", "sock")),
                    events=dict((k, int(v)) for k, v in (s.split() for s in (path / "memory.events").read_text().splitlines())),
                    cpu=dict((k, int(v)) for k, v in (s.split() for s in (path / "cpu.stat").read_text().splitlines())))
    except FileNotFoundError:
        # systemd removes a completed transient unit while monitoring can race.
        return None


def verify_group(path, memory):
    assert (path / "cpu.max").read_text().strip() == "400000 100000", "CPU quota missing"
    assert number(path / "memory.max") == memory, "memory cap missing"
    assert number(path / "memory.swap.max") == 0, "swap cap missing"
    assert number(path / "pids.max") == 128, "task cap missing"


class Session:
    def __init__(self, output, disk_read_mib=128, disk_write_mib=64):
        self.output = output.resolve()
        self.output.mkdir(parents=True, exist_ok=False)
        self.tag = f"nouredeen-load-{os.getpid()}"
        self.container = self.tag + "-pg"
        self.copy_container = self.tag + "-copy"
        self.snapshot_volume = self.tag + "-snapshot"
        self.copy_active = self.volume_created = False
        self.unit = None
        self.pg_group = self.bench_group = None
        self.created = False
        self.abort = threading.Event()
        self.done = threading.Event()
        self.reason = None
        self.phase = "setup"
        self.rows = []
        self.min_available = 999
        self.max_temp = 0
        self.watch = None
        self.disk_read_mib = disk_read_mib
        self.disk_write_mib = disk_write_mib

    def stop_owned(self):
        actions = []
        if self.copy_active:
            actions.append((("docker", "stop", "--time", "1", self.copy_container),
                            ("docker", "kill", self.copy_container)))
        if self.unit:
            actions.append((("systemctl", "--user", "stop", self.unit),
                            ("systemctl", "--user", "kill", "--signal=KILL", self.unit)))
        if self.created:
            actions.append((("docker", "stop", "--time", "3", self.container),
                            ("docker", "kill", self.container)))
        for graceful, force in actions:
            try:
                command(*graceful, timeout=20, check=False)
            except subprocess.TimeoutExpired:
                # Still stop the other owned group if slow I/O delays shutdown.
                print(f"Cleanup timeout for {graceful[-1]}; requesting forced termination.", flush=True)
                try:
                    command(*force, timeout=10, check=False)
                except subprocess.TimeoutExpired:
                    print(f"Termination request for {force[-1]} is still waiting on the system.", flush=True)

    def trip(self, reason):
        if self.abort.is_set():
            return
        self.reason = reason
        self.abort.set()
        (self.output / "guard-stop.json").write_text(json.dumps({"reason": reason, "time": time.time(), "phase": self.phase}, indent=2))
        print(f"GUARD STOP: {reason}", flush=True)
        self.stop_owned()

    def watchdog(self):
        hot = pressure = 0
        last = time.monotonic()
        disk_busy = host_sample()["disk_busy_ms"]
        try:
            with (self.output / "host-monitor.jsonl").open("w") as log:
                while not self.done.wait(1):
                    now = time.monotonic()
                    lag = now - last
                    last = now
                    sample = host_sample()
                    sample["disk_busy_percent"] = (sample["disk_busy_ms"] - disk_busy) / (lag * 10)
                    disk_busy = sample["disk_busy_ms"]
                    sample.update(phase=self.phase, pg=group_sample(self.pg_group), benchmark=group_sample(self.bench_group))
                    self.min_available = min(self.min_available, sample["available_gib"])
                    self.max_temp = max(self.max_temp, sample["cpu_temp_c"] or 0)
                    log.write(json.dumps(sample) + "\n")
                    log.flush()
                    hot = hot + 1 if (sample["cpu_temp_c"] or 0) >= 90 else 0
                    # io.max throttling itself contributes to global I/O PSI,
                    # even with an almost idle physical disk. Require actual
                    # device saturation as well before diagnosing host I/O
                    # contention. The bandwidth caps remain enforced by Linux.
                    io_pressure = sample["io_full"] >= 10 and sample["disk_busy_percent"] >= 80
                    # Throttled dirty-page writeback can also contribute to
                    # memory PSI despite abundant free RAM. Combine PSI with
                    # dwindling headroom; the 8-GiB floor and per-cgroup OOM /
                    # nonreclaimable-memory checks are unconditional.
                    memory_pressure = sample["available_gib"] < 12 and (sample["memory_some"] >= 2 or sample["memory_full"] >= 0.5)
                    pressured = memory_pressure or sample["cpu_some"] >= 40 or io_pressure
                    pressure = pressure + 1 if pressured else 0
                    reason = None
                    if sample["cpu_temp_c"] is None:
                        reason = "CPU temperature sensor became unavailable"
                    elif sample["available_gib"] < 8:
                        reason = "available RAM fell below 8 GiB"
                    elif hot >= 8 or (sample["cpu_temp_c"] or 0) >= 95:
                        reason = "CPU temperature reached the protective threshold"
                    elif sample["nvme_composite_c"] is None:
                        reason = "NVMe temperature sensor unavailable"
                    elif sample["nvme_composite_c"] >= sample["nvme_stop_c"]:
                        reason = "NVMe composite temperature reached the protective threshold"
                    elif pressure >= 5:
                        reason = f"sustained host pressure: memory={memory_pressure}, CPU PSI={sample['cpu_some']}, I/O={io_pressure}"
                    elif lag > 3:
                        reason = f"watchdog scheduling gap {lag:.1f}s"
                    for key, limit in (("pg", 8 * GIB), ("benchmark", 2 * GIB)):
                        state = sample[key]
                        if state and (state["events"].get("oom", 0) or state["nonreclaimable"] >= limit * 0.9):
                            reason = f"{key} approached its memory limit"
                    if reason:
                        self.trip(reason)
                        return
        except Exception as error:
            self.trip(f"watchdog failed: {error}")

    def setup(self):
        initial = host_sample()
        self.min_available = initial["available_gib"]
        self.max_temp = initial["cpu_temp_c"] or 0
        if initial["available_gib"] < 16 or initial["memory_some"] >= 1:
            raise RuntimeError(f"Insufficient starting headroom: {initial}")
        # Laptop turbo can cause a brief spike even while launching the shell.
        # Require a cool baseline before starting any benchmark work; keep the
        # watchdog's runtime temperature thresholds unchanged.
        cool = 0
        for attempt in range(120):
            initial = host_sample()
            if initial["available_gib"] < 16 or initial["memory_some"] >= 1:
                raise RuntimeError(f"Insufficient starting headroom: {initial}")
            if initial["cpu_temp_c"] is None:
                raise RuntimeError("CPU temperature sensor unavailable")
            if initial["nvme_composite_c"] is None:
                raise RuntimeError("NVMe temperature sensor unavailable")
            cool = cool + 1 if initial["cpu_temp_c"] < 80 and initial["nvme_composite_c"] < initial["nvme_stop_c"] - 3 else 0
            if cool >= 5:
                break
            if attempt % 30 == 0:
                print(f"Waiting for a cool baseline: CPU {initial['cpu_temp_c']:.0f} C, NVMe composite {initial['nvme_composite_c']:.1f} C", flush=True)
            time.sleep(1)
        else:
            raise RuntimeError("CPU / NVMe did not settle below their starting thresholds")
        self.min_available = initial["available_gib"]
        self.max_temp = initial["cpu_temp_c"]
        info = json.loads(command("docker", "inspect", ORIGINAL).stdout)[0]
        assert not info["State"]["Running"], "original PG must remain stopped"
        assert info["Config"]["Image"] == IMAGE, "unexpected PostgreSQL image"
        volume = next(m["Name"] for m in info["Mounts"] if m["Destination"] == "/var/lib/postgresql")
        assert volume == ORIGINAL, "unexpected PostgreSQL volume"
        assert not command("docker", "ps", "-q", "--filter", f"volume={volume}").stdout.strip(), "source volume is in use"
        config = (HERE / "tools/setup-local.sh").read_text().split("<<'CONF'\n", 1)[1].split("\nCONF", 1)[0]
        (self.output / "pg18.conf").write_text(config + "\n")
        (self.output / "bin").mkdir()
        wrapper = self.output / "bin/psql"
        wrapper.write_text(f'#!/bin/sh\nexec docker exec -i {self.container} psql -h /var/run/postgresql -U postgres "$@"\n')
        wrapper.chmod(0o755)
        plan = dict(initial=initial, binary_sha256=hashlib.sha256((HERE / "target/release/conduit").read_bytes()).hexdigest(),
                    limits={"postgres_cpu": 4, "postgres_memory_gib": 8, "app_plus_loadgen_cpu": 4, "app_plus_loadgen_memory_gib": 2,
                            "disk_read_mib_s": self.disk_read_mib, "disk_write_mib_s": self.disk_write_mib, "reserve_available_gib": 8},
                    image=IMAGE, think_scale=0.1, seed="conduit_seed", note="Shared laptop, resource-capped local result, not official capacity.")
        plan["database_strategy"] = "Btrfs reflink of stopped volume, source read-only; stages share the disposable snapshot database"
        plan["watchdog"] = dict(interval_s=1, immediate_temperature_c=95,
                                sustained_temperature_c=90, sustained_temperature_samples=8,
                                reserve_available_gib=8, pressure_headroom_gib=12,
                                max_scheduling_gap_s=3, nvme_stop_c=initial["nvme_stop_c"])
        plan["power_profile"] = {str(p): p.read_text().strip() for p in (
            Path("/sys/firmware/acpi/platform_profile"),
            Path("/sys/devices/system/cpu/cpu0/cpufreq/energy_performance_preference"),
            Path("/sys/class/power_supply/ACAD/online")) if p.exists()}
        (self.output / "plan.json").write_text(json.dumps(plan, indent=2) + "\n")
        self.watch = threading.Thread(target=self.watchdog, daemon=True)
        self.watch.start()
        assert command("docker", "volume", "inspect", self.snapshot_volume, check=False).returncode != 0, "snapshot volume already exists"
        command("docker", "volume", "create", self.snapshot_volume)
        self.volume_created = True
        self.copy_active = True
        # --reflink=always must succeed: never fall back to copying gigabytes.
        # The source is mounted read-only and no source PostgreSQL is running.
        command("docker", "run", "--rm", "--name", self.copy_container,
                "--cpus=0.5", "--memory=128m", "--memory-swap=128m", "--pids-limit=32",
                "--device-read-bps", f"/dev/nvme0n1:{self.disk_read_mib}mb",
                "--device-write-bps", f"/dev/nvme0n1:{self.disk_write_mib}mb",
                "--mount", f"type=volume,src={volume},dst=/source,readonly",
                "--mount", f"type=volume,src={self.snapshot_volume},dst=/snapshot",
                "--user", "0:0", "--entrypoint", "/bin/cp", IMAGE,
                "-a", "--reflink=always", "/source/.", "/snapshot/", timeout=90)
        self.copy_active = False
        if self.abort.is_set():
            raise RuntimeError(self.reason)
        print("Prepared disposable reflink snapshot; original seed volume remains read-only.", flush=True)
        command("docker", "run", "--detach", "--rm", "--name", self.container,
                "--cpus=4", "--memory=8g", "--memory-swap=8g", "--pids-limit=128", "--shm-size=1g", "--cpu-shares=128",
                "--device-read-bps", f"/dev/nvme0n1:{self.disk_read_mib}mb", "--device-write-bps", f"/dev/nvme0n1:{self.disk_write_mib}mb",
                "--mount", f"type=volume,src={self.snapshot_volume},dst=/var/lib/postgresql",
                "--mount", f"type=bind,src={self.output}/pg18.conf,dst=/etc/challenge-postgresql.conf,readonly",
                "-p", "127.0.0.1::5432", IMAGE, "-c", "config_file=/etc/challenge-postgresql.conf")
        self.created = True
        pg = json.loads(command("docker", "inspect", self.container).stdout)[0]
        self.port = pg["NetworkSettings"]["Ports"]["5432/tcp"][0]["HostPort"]
        self.pg_group = cgroup_for_pid(pg["State"]["Pid"])
        verify_group(self.pg_group, 8 * GIB)
        (self.output / "pg-cgroup.json").write_text(json.dumps({name: (self.pg_group / name).read_text() for name in ("cpu.max", "memory.max", "memory.swap.max", "io.max")}, indent=2))
        for _ in range(60):
            if self.abort.is_set():
                raise RuntimeError(self.reason)
            if command("docker", "exec", self.container, "pg_isready", "-q", "-U", "postgres", check=False).returncode == 0:
                break
            time.sleep(1)
        else:
            raise RuntimeError("PG startup timeout")
        counts = command(str(wrapper), "-XAt", "-d", "conduit_seed", "-c", "SELECT (SELECT count(*) FROM users), (SELECT count(*) FROM articles)", timeout=60).stdout.strip()
        assert counts == "100000|500000", counts
        print("Ready: full seed, 4 CPU/8 GiB PostgreSQL; app + generator limited to 4 CPU/2 GiB.", flush=True)

    def run(self, users, hold=False, suffix=""):
        if self.abort.is_set():
            raise RuntimeError(self.reason)
        name = f"{'hold' if hold else 'probe'}-{users}{suffix}"
        self.phase = name
        directory = self.output / name
        self.unit = self.tag + "-" + name
        ramp, measure, tail = (60, 300, 15) if hold else (20, 60, 10)
        cmd = ["systemd-run", "--user", "--quiet", "--wait", "--pipe", "--collect", "--unit", self.unit,
               "--working-directory", str(HERE), "-p", "CPUQuota=400%", "-p", "CPUQuotaPeriodSec=100ms",
               "-p", "MemoryHigh=1536M", "-p", "MemoryMax=2G", "-p", "MemorySwapMax=0", "-p", "OOMPolicy=kill",
               "-p", "TasksMax=128", "-p", "RuntimeMaxSec=900", "-p", "Nice=10", "-p", "IOWeight=10", "-p", "LimitNOFILE=200000",
               "/usr/bin/env", f"PATH={self.output}/bin:{os.environ['PATH']}", f"PGPORT={self.port}",
               sys.executable, str(Path(__file__).resolve()), "--child",
               "--binary", str(HERE / "target/release/conduit"), "--loadgen", str(HERE / ".local/loadgen"),
               "--existing-database", "conduit_seed",
               "--pg-container", self.container, "--loadgen-procs", "2", "--users", str(users), "--port", "3110",
               "--ramp", f"{ramp}s", "--measure", f"{measure}s", "--tail", f"{tail}s", "--output", str(directory)]
        print(f"START {name}: {ramp}s ramp + {measure}s measurement", flush=True)
        with (self.output / f"{name}.log").open("w") as log:
            proc = subprocess.Popen(cmd, stdout=log, stderr=subprocess.STDOUT)
            try:
                while proc.poll() is None:
                    if self.abort.wait(1):
                        raise RuntimeError(self.reason)
                    if self.bench_group is None:
                        cg = command("systemctl", "--user", "show", self.unit, "-p", "ControlGroup", "--value", check=False).stdout.strip()
                        if cg:
                            path = Path("/sys/fs/cgroup" + cg)
                            if path.exists():
                                verify_group(path, 2 * GIB)
                                self.bench_group = path
                if proc.returncode != 0:
                    raise RuntimeError(f"{name} failed: see {name}.log")
            finally:
                if proc.poll() is None:
                    command("systemctl", "--user", "stop", self.unit, timeout=20, check=False)
                    proc.wait(timeout=20)
                self.bench_group = None
                self.unit = None
        merged = json.loads((directory / "merged.json").read_text())
        row = dict(run=name, users=users, measure_s=measure, **merged["overall"], **merged["verdict"])
        row["login_p99_ms"] = next((e["p99_ms"] for e in merged["endpoints"] if e["name"] == "POST /api/users/login"), None)
        self.rows.append(row)
        self.save()
        print(f"RESULT {name}: {row['rps']:.0f} req/s, p95 {row['p95_ms']:.1f} ms, p99 {row['p99_ms']:.1f} ms, errors {row['errors']}, pass={row['pass']}, LG-limited={row['lg_limited']}", flush=True)
        return row

    def save(self):
        (self.output / "summary.json").write_text(json.dumps(dict(runs=self.rows, guard_stop=self.reason,
                min_available_gib=self.min_available, max_cpu_temp_c=self.max_temp), indent=2) + "\n")

    def close(self):
        self.phase = "cleanup"
        self.done.set()
        if self.watch:
            self.watch.join(timeout=25)
        self.save()
        self.stop_owned()
        if self.volume_created:
            try:
                result = command("docker", "volume", "rm", self.snapshot_volume, timeout=30, check=False)
                (self.output / "snapshot-cleanup.json").write_text(json.dumps(dict(volume=self.snapshot_volume,
                        removed=result.returncode == 0, stderr=result.stderr), indent=2))
            except subprocess.TimeoutExpired:
                print(f"Snapshot cleanup still pending: {self.snapshot_volume}", flush=True)


def main():
    if len(sys.argv) > 1 and sys.argv[1] == "--child":
        verify_group(cgroup_for_pid(os.getpid()), 2 * GIB)
        os.execv(sys.executable, [sys.executable, str(HERE / "tools/bench.py"), *sys.argv[2:]])
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--confirm-users", type=int, help="only a five-minute confirmation of an earlier passing load")
    parser.add_argument("--disk-read-mib", type=int, default=128, help="disk read cap, 1..128 MiB/s")
    parser.add_argument("--disk-write-mib", type=int, default=64, help="disk write cap, 1..64 MiB/s")
    args = parser.parse_args()
    if args.confirm_users is not None and not 1 <= args.confirm_users <= 20000:
        parser.error("confirmation must use 1..20000 VUs")
    if not 1 <= args.disk_read_mib <= 128 or not 1 <= args.disk_write_mib <= 64:
        parser.error("disk caps must be within 1..128 MiB/s reads and 1..64 MiB/s writes")
    session = Session(args.output, args.disk_read_mib, args.disk_write_mib)
    exit_code = 0
    for sig in (signal.SIGTERM, signal.SIGINT):
        signal.signal(sig, lambda *_: (_ for _ in ()).throw(KeyboardInterrupt()))
    try:
        session.setup()
        if args.confirm_users:
            session.run(args.confirm_users, hold=True)
            return
        best = 0
        failed = None
        for users in (1000, 4000, 8000, 12000, 16000, 20000):
            row = session.run(users)
            if row["lg_limited"]:
                break
            if not row["pass"]:
                failed = users
                break
            best = users
        if best and failed and failed - best > 2000:
            middle = (best + failed) // 2
            row = session.run(middle)
            if row["pass"] and not row["lg_limited"]:
                best = middle
        if best:
            row = session.run(best, hold=True)
            if not row["pass"] and not row["lg_limited"]:
                session.run(best * 9 // 10, hold=True, suffix="-stepdown")
    except (Exception, KeyboardInterrupt) as error:
        exit_code = 1
        if not session.reason:
            session.reason = str(error) or "interrupted"
            if isinstance(error, subprocess.CalledProcessError):
                session.reason += ": " + (error.stderr or "")[-2000:]
        print(f"STOP: {session.reason}", flush=True)
    finally:
        session.close()
    return exit_code


if __name__ == "__main__":
    sys.exit(main())
