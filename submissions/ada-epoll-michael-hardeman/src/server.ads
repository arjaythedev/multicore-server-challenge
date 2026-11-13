--  HTTP/1.1 reactors: one task per SO_REUSEPORT listener, each with its own epoll set, edge-triggered, and its
--  own descriptor table. A connection has at most one request in flight; pipelined requests wait in its input
--  buffer.
--
--  Proved (SPARK silver, under the Jorvik profile) free of run-time errors and data races.
with Jobs;

package Server with SPARK_Mode is

   Reactors     : constant := 4;
   Last_Reactor : constant Jobs.Reactor_Id := Jobs.Reactor_Id (Reactors - 1);

   --  The reactor tasks exist from start-up and give themselves their own descriptor tables at once. Ready
   --  returns once they all have (open Postgres connections only after that).
   procedure Ready;

   --  Lets the reactors listen on Settings' address and port.
   procedure Start;

end Server;
