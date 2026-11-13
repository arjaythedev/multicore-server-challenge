--  Counters for one task of a pipeline stage: how many batches and jobs it took, how long the oldest job of
--  each batch had waited in the queue, and how long the task worked on the batch. With STATS=1 each task logs
--  its counters every 10 seconds; each task owns its counters, so nothing is shared.
--
--  Proved free of run-time errors (SPARK silver).
with Effects;
with Linux; use Linux;
with Settings;

package Stage_Stats with SPARK_Mode is

   type Counters is private;

   --  Counters from zero, starting at Now.
   procedure Start (This : out Counters; Now : Milliseconds) with Global => null, Pre => Now in 0 .. 2 ** 62;

   --  One batch of Jobs, whose oldest job was queued at Queued, taken at Taken and answered at Done.
   procedure Add (This : in out Counters; Jobs : Natural; Queued, Taken, Done : Milliseconds) with Global => null;

   --  Once 10 seconds have passed since Start, logs the counters as Name's and starts again from zero at Now.
   procedure Report (This : in out Counters; Name : String; Now : Milliseconds)
      with Global => (Input => Settings.Stats_Image, In_Out => Effects.World),
           Pre    => Name'Length <= 40 and then Now in 0 .. 2 ** 62;

private

   Limit : constant := 2 ** 62;
   subtype Total is Long_Long_Integer range 0 .. Limit;

   type Counters is record
      Since    : Milliseconds := 0;
      Batches  : Total := 0;
      Jobs     : Total := 0;
      Wait     : Total := 0;   --  summed over the batches, milliseconds
      Max_Wait : Total := 0;
      Work     : Total := 0;
   end record;

end Stage_Stats;
