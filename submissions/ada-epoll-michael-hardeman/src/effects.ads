--  What the proved stages do to the rest of the process: hand jobs to other tasks, read the clock, log. The
--  bodies are thin calls into the tasking code (Job_Queues) and the system, outside SPARK; the contracts state
--  what the proofs rely on: a job handed on is no longer the caller's, and the clock's range.
with Jobs; use Jobs;
with Model; use type Model.Unix_Seconds;

package Effects
  with SPARK_Mode, Abstract_State => (World with Synchronous, External), Initializes => World
is

   --  Queue the job for the stage its phase belongs to.
   procedure Submit (Item : in out Job_Access)
      with Global => (In_Out => World),
           Pre    => Item /= null,
           Post   => Item = null;

   --  Send the finished job back to the reactor that owns its connection.
   procedure Complete (Item : in out Job_Access)
      with Global => (In_Out => World),
           Pre    => Item /= null,
           Post   => Item = null;

   --  A reference to a job handed on, kept by its reactor only to flag it abandoned; it owns nothing.
   type Job_Handle is private;
   No_Job : constant Job_Handle;

   --  Submit, keeping a handle to the job.
   procedure Submit_Tracked (Item : in out Job_Access; Handle : out Job_Handle)
      with Global => (In_Out => World),
           Pre    => Item /= null,
           Post   => Item = null;

   --  Tell the stages working on a job still in flight that its client hung up.
   procedure Abandon (Handle : Job_Handle)
      with Global => (In_Out => World);

   --  The jobs finished for this reactor, chained by Next (null when none).
   procedure Take_Completed (Reactor : Reactor_Id; Chain : out Job_Access)
      with Global => (In_Out => World);

   --  Whether the job's client hung up (a flag its reactor may set at any time).
   procedure Check_Abandoned (Item : Job_Access; Abandoned : out Boolean)
      with Global => (In_Out => World),
           Pre    => Item /= null;

   --  Seconds since 1970 (CLOCK_REALTIME_COARSE).
   procedure Read_Clock (Now : out Model.Unix_Seconds)
      with Global => (In_Out => World),
           Post   => Now in 0 .. 10 ** 15;

   --  A line on standard error.
   procedure Log (Message : String)
      with Global => (In_Out => World);

private
   pragma SPARK_Mode (Off);

   type Job_Handle is new Job_Access;
   No_Job : constant Job_Handle := null;

end Effects;
