# Exercise the real wire queue with a recording transport, without a database.
# GROUP_COMMIT=1 crystal run test/group_flush.cr
require "../src/sys"
require "../src/buf"
require "../src/pg"

class Job
  property kind = 0
  property solo = false
  property sub = Pointer(Job).null
  property tag_off = Pointer(Int32).null
  property nsub = 0

  def initialize(cap : Int32)
  end
end

module App
  K_WRITE_BATCH = 21

  def self.write?(job : Job) : Bool
    true
  end
end

module Uring
  class_property sends = 0
  class_property timers = 0

  def self.arm_timer(ns : Int64) : Nil
    self.timers += 1
  end

  def self.pg_send(idx : Int32, fd : Int32, p : UInt8*, n : Int32) : Nil
    self.sends += 1
  end
end

module Pg
  def self.test_connection : Conn
    c = Conn.new(0, -1)
    @@conns = Pointer(Conn).malloc(1, c)
    @@n = 1
    c
  end
end

def enqueue_write
  c = Pg.write_pick.not_nil!
  Pg.execute(c, Pg.bind(c, 0, 0))
  Pg.sync(c, Job.new(0))
end

raise "set GROUP_COMMIT=1" unless ENV["GROUP_COMMIT"]? == "1"
c = Pg.test_connection
enqueue_write
Pg.flush
raise "partial group bypassed its collection window" if c.sending
raise "partial group has no wakeup" unless Uring.timers > 0

# The 49th request closes a full group and starts another. The new group's
# window must not postpone sending the completed group (indefinitely under load).
48.times { enqueue_write }
raise "expected a full queued group and a partial group" unless c.pending == 1 && c.group.try(&.nsub) == 1
Pg.flush
raise "completed group starved behind a newer collection window" unless c.sending && Uring.sends == 1
raise "trailing group not closed before sending" unless c.group.nil? && c.pending == 2
puts "full group flushes immediately with a newer partial group"

# A completed send must clear the bypass flag, so a fresh sparse group still
# receives its own collection window.
c.sending = false
c.sbuf.clear
enqueue_write
Pg.flush
raise "previous full group bypassed a fresh collection window" if c.sending
puts "fresh partial group retains its collection window"
