--  The queues between the stages, and the way finished jobs go back to their reactors.
--
--  SPARK, under the Jorvik profile: callers are proved against the contracts (a job pushed is the queue's until
--  a task takes it), the package is proved free of data races; the protected bodies themselves are audited
--  (see the private part). A queue is two stacks linked through the jobs' Next (pushed newest first, taken
--  oldest first), so it has no tail pointer to alias. Taken Newest_First, jobs come off the pushed stack
--  directly, last in first out.
with Jobs; use Jobs;
with Linux;

package Job_Queues with SPARK_Mode is

   protected type Job_Queue is

      --  Item and every job chained after it join the queue, stamped with Now.
      procedure Push (Item : in out Job_Access; Now : Linux.Milliseconds) with Global => null, Post => Item = null;

      --  Blocks until a job is queued; Queued is when the oldest one arrived.
      entry Wait_Oldest (Queued : out Linux.Milliseconds) with Global => null;

      --  Blocks until a job is queued, then moves up to Into'Length of them, oldest first (newest first if
      --  Newest_First: only for a queue nobody calls Wait_Oldest on), into
      --  Into (Into'First .. Into'First + Count - 1), each on its own (Next null).
      entry Take (Into : in out Job_List; Count : out Natural; Newest_First : Boolean)
      with
        Global => null,
        Pre    => (for all Index in Into'Range => Into (Index) = null),
        Post   => Count <= Into'Length
                  and then (for all Index in Into'Range => (if Index - Into'First >= Count then Into (Index) = null));

      function Length return Natural with Global => null;

   private
      --  Outside SPARK: GNATprove 15 stops with an internal error on a protected component designating Job
      --  (a record holding both its Next link and a Buffer). The bodies are short and audited; the contracts
      --  above are what the proved callers rely on.
      pragma SPARK_Mode (Off);
      Incoming  : Job_Access; --  newest first
      Outgoing  : Job_Access; --  oldest first; all older than Incoming's
      Count_Now : Natural := 0;
   end Job_Queue;

   Read_Queue  : Job_Queue;
   Write_Queue : Job_Queue;
   Hash_Queue  : Job_Queue;   --  taken newest first (see Lanes.Hasher)

   --  Queue a job for the stage its phase belongs to.
   procedure Submit (Item : in out Job_Access) with Post => Item = null;

   --  Finished jobs go back to their reactor: a stack and an eventfd per reactor (Socket_IO.Event_Counter).
   function Signals_Ready return Boolean;
   function Completion_Signal (Reactor : Reactor_Id) return Linux.File_Descriptor;

   procedure Complete (Item : in out Job_Access) with Pre => Item /= null, Post => Item = null;

   --  Every job finished for Reactor, chained by Next (null when none).
   procedure Take_Completed (Reactor : Reactor_Id; Chain : out Job_Access);

end Job_Queues;
