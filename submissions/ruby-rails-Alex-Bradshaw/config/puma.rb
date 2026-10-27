# This configuration file will be evaluated by Puma. The top-level methods that
# are invoked here are part of Puma's configuration DSL. For more information
# about methods provided by the DSL, see https://puma.io/puma/Puma/DSL.html.
#
# Puma starts a configurable number of processes (workers) and each process
# serves each request in a thread from an internal thread pool.
#
# You can control the number of workers using ENV["WEB_CONCURRENCY"]. You
# should only set this value when you want to run 2 or more workers. The
# default is already 1. You can set it to `auto` to automatically start a worker
# for each available processor.
#
# The ideal number of threads per worker depends both on how much time the
# application spends waiting for IO operations and on how much you wish to
# prioritize throughput over latency.
#
# As a rule of thumb, increasing the number of threads will increase how much
# traffic a given process can handle (throughput), but due to CRuby's
# Global VM Lock (GVL) it has diminishing returns and will degrade the
# response time (latency) of the application.
#
# The default is set to 3 threads as it's deemed a decent compromise between
# throughput and latency for the average Rails application.
#
# Any libraries that use a connection pool or another resource pool should
# be configured to provide at least as many connections as the number of
# threads. This includes Active Record's `pool` parameter in `database.yml`.
threads_count = Integer(ENV.fetch("RAILS_MAX_THREADS", 5))
threads threads_count, threads_count

# Clustered mode: one Ruby process can only run Ruby code on one core at a time (the GVL), so to use all the
# box's cores we run several worker processes. start.sh sets one per core; 1 means plain single mode.
worker_count = Integer(ENV.fetch("WEB_CONCURRENCY", 1))
workers worker_count

# Each worker has its own Active Record pool of threads_count connections, and the challenge allows 95 in total.
if worker_count * threads_count > 95
  raise "#{worker_count} workers x #{threads_count} threads = #{worker_count * threads_count} Postgres connections; the limit is 95"
end

# Boot Rails once and fork the workers from it, so they share memory and start quickly.
# (Rails 7.1+ reconnects Active Record in each forked worker by itself.)
preload_app! if worker_count > 1

# Rule 9: "If your server crashes, it isn't restarted." Puma's cluster master normally replaces any worker that
# dies (its check_workers loop reaps the dead worker, then spawn_workers tops the count back up), and there's no
# setting to turn that off. So spawn_workers is allowed to run once, at boot, and never again: a worker that
# dies stays dead and the remaining workers carry on.
require "puma/cluster"
unless Puma::Cluster.method_defined?(:spawn_workers) || Puma::Cluster.private_method_defined?(:spawn_workers)
  raise "Puma::Cluster#spawn_workers is gone (Puma upgraded?): re-check the no-respawn patch in config/puma.rb"
end
module SpawnWorkersOnlyAtBoot
  def spawn_workers
    return if @initial_workers_spawned

    super
    @initial_workers_spawned = true
  end
end
Puma::Cluster.prepend(SpawnWorkersOnlyAtBoot)

# Say so in the log when it happens, so a crash during a run is visible.
after_worker_shutdown do |worker|
  next if worker.process_status&.success?

  warn "[rule 9] worker #{worker.index} (pid #{worker.pid}) died (#{worker.process_status.inspect}); not replacing it"
end

# Listen on HOST:PORT from the challenge's runtime contract (127.0.0.1:3000 behind Nginx).
bind "tcp://#{ENV.fetch("HOST", "127.0.0.1")}:#{ENV.fetch("PORT", 3000)}"

# Nginx keeps upstream connections idle for up to 60 s; the spec requires us to hold them for at least 65 s
# so Nginx never reuses a socket we've just closed.
persistent_timeout 65

# Allow puma to be restarted by `bin/rails restart` command.
plugin :tmp_restart

# Specify the PID file. Defaults to tmp/pids/server.pid in development.
# In other environments, only set the PID file if requested.
pidfile ENV["PIDFILE"] if ENV["PIDFILE"]
