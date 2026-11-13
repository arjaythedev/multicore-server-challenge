with Server;
with Socket_IO;

package body Job_Queues with SPARK_Mode is

   use type Linux.File_Descriptor;

   ------------------
   -- Reverse_Onto --
   ------------------

   --  Every job of From moves onto the front of Into, so From's order is reversed.
   procedure Reverse_Onto (From, Into : in out Job_Access) with Post => From = null is begin
      while From /= null loop
         declare
            Node : constant Job_Access := From;
         begin
            From      := Node.Next;
            Node.Next := Into;
            Into      := Node;
         end;
      end loop;
   end Reverse_Onto;

   ---------------
   -- Job_Queue --
   ---------------

   protected body Job_Queue is
      pragma SPARK_Mode (Off); --  see the spec's private part

      ----------
      -- Push --
      ----------

      procedure Push (Item : in out Job_Access; Now : Linux.Milliseconds) is
         Node : Job_Access;
      begin
         while Item /= null loop
            Node        := Item;
            Item        := Node.Next;
            Node.Queued := Now;
            Node.Next   := Incoming;
            Incoming    := Node;
            Count_Now   := (if Count_Now < Natural'Last then Count_Now + 1 else Count_Now);
         end loop;
      end Push;

      -----------------
      -- Wait_Oldest --
      -----------------

      entry Wait_Oldest (Queued : out Linux.Milliseconds) when Count_Now > 0 is begin
         if Outgoing = null then
            Reverse_Onto (Incoming, Outgoing);
         end if;
         Queued := (if Outgoing = null then 0 else Outgoing.Queued);
      end Wait_Oldest;

      ----------
      -- Take --
      ----------

      entry Take (Into : in out Job_List; Count : out Natural; Newest_First : Boolean)
        when Count_Now > 0
      is
         Node : Job_Access;
      begin
         Count := 0;
         for Index in Into'Range loop
            pragma Loop_Invariant
              (Count = Index - Into'First and then (for all Later in Index .. Into'Last => Into (Later) = null));
            if Newest_First and then Incoming /= null then
               Node     := Incoming;
               Incoming := Node.Next;
            else
               if Outgoing = null then
                  Reverse_Onto (Incoming, Outgoing);
               end if;
               exit when Outgoing = null;
               Node     := Outgoing;
               Outgoing := Node.Next;
            end if;
            Node.Next    := null;
            Into (Index) := Node;
            Count        := Count + 1;
         end loop;
         Count_Now := (if Count_Now > Count then Count_Now - Count else 0);
      end Take;

      ------------
      -- Length --
      ------------

      function Length return Natural is (Count_Now);

   end Job_Queue;

   ------------
   -- Submit --
   ------------

   procedure Submit (Item : in out Job_Access) is
      Now : Linux.Milliseconds;
   begin
      if Item = null then
         return;
      end if;
      Socket_IO.Read_Monotonic (Now);
      case Item.Stage is
         when Reading | Reading_Back => Read_Queue.Push (Item, Now);
         when Hashing | Verifying    => Hash_Queue.Push (Item, Now);
         when Writing                => Write_Queue.Push (Item, Now);
      end case;
   end Submit;

   protected type Completion_Stack is
      procedure Push (Item : in out Job_Access; Was_Empty : out Boolean) with Post => Item = null;
      procedure Take_All (Chain : out Job_Access);
   private
      pragma SPARK_Mode (Off); --  as Job_Queue's
      First : Job_Access;
   end Completion_Stack;

   ----------------------
   -- Completion_Stack --
   ----------------------

   protected body Completion_Stack is
      pragma SPARK_Mode (Off);

      ----------
      -- Push --
      ----------

      procedure Push (Item : in out Job_Access; Was_Empty : out Boolean) is begin
         Was_Empty := First = null;
         Reverse_Onto (Item, First);
      end Push;

      --------------
      -- Take_All --
      --------------

      procedure Take_All (Chain : out Job_Access) is begin
         Chain := First;
         First := null;
      end Take_All;

   end Completion_Stack;

   Completed : array (Reactor_Id) of Completion_Stack;
   Signals   : constant array (Reactor_Id) of Linux.File_Descriptor :=
     [for Reactor in Reactor_Id => Socket_IO.Event_Counter (Natural (Reactor))];

   -------------------
   -- Signals_Ready --
   -------------------

   function Signals_Ready return Boolean is
     (for all Reactor in 0 .. Server.Last_Reactor => Signals (Reactor) /= Linux.No_Descriptor);

   -----------------------
   -- Completion_Signal --
   -----------------------

   function Completion_Signal (Reactor : Reactor_Id) return Linux.File_Descriptor is (Signals (Reactor));

   --------------
   -- Complete --
   --------------

   procedure Complete (Item : in out Job_Access) is
      Reactor   : constant Reactor_Id := Item.Reply.Reactor;
      Was_Empty : Boolean;
   begin
      Completed (Reactor).Push (Item, Was_Empty);
      if Was_Empty then
         Socket_IO.Signal (Signals (Reactor)); --  later pushes ride on the wakeup already pending
      end if;
   end Complete;

   --------------------
   -- Take_Completed --
   --------------------

   procedure Take_Completed (Reactor : Reactor_Id; Chain : out Job_Access) is begin
      Completed (Reactor).Take_All (Chain);
   end Take_Completed;

end Job_Queues;
