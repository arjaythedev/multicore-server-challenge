--  The tasks behind the reactors. Read lanes and the write lane each own one Postgres connection: they take
--  every job waiting (up to a cap), pipeline each job's statements, then read the replies back in order and
--  render each job's response. Hashers run bcrypt.
--
--  Proved (SPARK silver, under the Jorvik profile) free of run-time errors and data races, and to hand every
--  job they take on: each is answered, or queued for its next stage.
package Lanes with SPARK_Mode is

   --  How many of each task there are. They exist from start-up and wait for Start.
   Read_Lanes  : constant := 8;
   Write_Lanes : constant := 2;
   Hashers     : constant := 3;

   --  Open one connection to DATABASE_URL and prepare every statement, so start-up fails early on a bad URL or
   --  schema (the reason is logged).
   procedure Check_Database (Reachable : out Boolean);

   procedure Start;

end Lanes;
