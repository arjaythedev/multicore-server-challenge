with Ada.Text_IO;
with Job_Queues;
with Linux;

package body Effects with SPARK_Mode => Off, Refined_State => (World => null) is

   ------------
   -- Submit --
   ------------

   procedure Submit (Item : in out Job_Access) is begin
      Job_Queues.Submit (Item);
      Item := null;
   end Submit;

   --------------
   -- Complete --
   --------------

   procedure Complete (Item : in out Job_Access) is begin
      Job_Queues.Complete (Item);
      Item := null;
   end Complete;

   --------------------
   -- Submit_Tracked --
   --------------------

   procedure Submit_Tracked (Item : in out Job_Access; Handle : out Job_Handle) is begin
      Handle := Job_Handle (Item);
      Job_Queues.Submit (Item);
      Item := null;
   end Submit_Tracked;

   -------------
   -- Abandon --
   -------------

   procedure Abandon (Handle : Job_Handle) is begin
      if Handle /= null then
         Handle.Abandoned := True;   --  the job stays alive until it comes back to its reactor
      end if;
   end Abandon;

   --------------------
   -- Take_Completed --
   --------------------

   procedure Take_Completed (Reactor : Reactor_Id; Chain : out Job_Access) is begin
      Job_Queues.Take_Completed (Reactor, Chain);
   end Take_Completed;

   ---------------------
   -- Check_Abandoned --
   ---------------------

   procedure Check_Abandoned (Item : Job_Access; Abandoned : out Boolean) is begin
      Abandoned := Item.Abandoned;
   end Check_Abandoned;

   ----------------
   -- Read_Clock --
   ----------------

   procedure Read_Clock (Now : out Model.Unix_Seconds) is
      Time : constant Model.Unix_Seconds := Linux.Now;
   begin
      Now := (if Time < 0 then 0 elsif Time > 10 ** 15 then 10 ** 15 else Time);
   end Read_Clock;

   ---------
   -- Log --
   ---------

   procedure Log (Message : String) is begin
      Ada.Text_IO.Put_Line (Ada.Text_IO.Standard_Error, Message);
   end Log;

end Effects;
