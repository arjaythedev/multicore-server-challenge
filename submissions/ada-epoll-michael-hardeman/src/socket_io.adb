with GNAT.OS_Lib;
with Interfaces.C; use Interfaces.C;
with Server;

package body Socket_IO with SPARK_Mode => Off, Refined_State => (Kernel => null, Start_Up => Counters) is

   Counters : array (0 .. Max_Counters - 1) of File_Descriptor := [others => No_Descriptor];

   -------------------
   -- Event_Counter --
   -------------------

   function Event_Counter (Index : Natural) return File_Descriptor is (Counters (Index));

   -------------
   -- Receive --
   -------------

   procedure Receive (Socket : File_Descriptor; Into : in out String; Count : out Integer; Error : out Error_Code) is
      Got : constant long := Linux.Read (Socket, Into (Into'First)'Address, size_t (Into'Length));
   begin
      if Got < 0 or else Got > long (Into'Length) then
         Count := -1;
         Error := Last_Error;
      else
         Count := Integer (Got);
         Error := 0;
      end if;
   end Receive;

   ----------
   -- Send --
   ----------

   procedure Send (Socket : File_Descriptor; From : String; Count : out Integer; Error : out Error_Code) is
      Sent : constant long := Linux.Send (Socket, From (From'First)'Address, size_t (From'Length), MSG_NOSIGNAL);
   begin
      if Sent < 0 or else Sent > long (From'Length) then
         Count := -1;
         Error := Last_Error;
      else
         Count := Integer (Sent);
         Error := 0;
      end if;
   end Send;

   -------------
   -- Connect --
   -------------

   procedure Connect (Address : IPv4_Address; Port : Port_Number; Socket : out File_Descriptor) is begin
      Socket := Connect_To (Address, Port);
   end Connect;

   -----------
   -- Close --
   -----------

   procedure Close (Socket : File_Descriptor) is begin
      Linux.Close (Socket);
   end Close;

   ------------------
   -- Random_Bytes --
   ------------------

   procedure Random_Bytes (Into : out String) is begin
      Linux.Random_Bytes (Into);
   end Random_Bytes;

   ---------------
   -- Send_Pair --
   ---------------

   procedure Send_Pair
     (Socket : File_Descriptor; Head, Content : String; Count : out Integer; Error : out Error_Code)
   is
      Vectors : aliased IO_Vector_Array (1 .. 2) :=
        [(Head'Address, size_t (Head'Length)), (Content'Address, size_t (Content'Length))];
      Written : constant long := Write_Vector (Socket, Vectors'Address, (if Content'Length = 0 then 1 else 2));
   begin
      if Written < 0 or else Written > long (Head'Length) + long (Content'Length) then
         Count := -1;
         Error := Last_Error;
      else
         Count := Integer (Written);
         Error := 0;
      end if;
   end Send_Pair;

   -------------------
   -- Accept_Client --
   -------------------

   procedure Accept_Client (Listener : File_Descriptor; Socket : out File_Descriptor; Error : out Error_Code) is begin
      Socket := Accept_Connection (Listener);
      Error  := (if Socket = No_Descriptor then Last_Error else 0);
   end Accept_Client;

   ------------------
   -- Set_No_Delay --
   ------------------

   procedure Set_No_Delay (Socket : File_Descriptor) is begin
      Linux.Set_No_Delay (Socket);
   end Set_No_Delay;

   -----------
   -- Watch --
   -----------

   procedure Watch (Epoll, Descriptor : File_Descriptor; Events : Event_Mask) is begin
      Linux.Watch (Epoll, Descriptor, Events);
   end Watch;

   -------------
   -- Unwatch --
   -------------

   procedure Unwatch (Epoll, Descriptor : File_Descriptor) is begin
      Linux.Unwatch (Epoll, Descriptor);
   end Unwatch;

   -----------
   -- Drain --
   -----------

   procedure Drain (Counter : File_Descriptor) is begin
      Linux.Drain (Counter);
   end Drain;

   --------------------
   -- Read_Monotonic --
   --------------------

   procedure Read_Monotonic (Now : out Milliseconds) is
      Time : constant Milliseconds := Monotonic_Clock;
   begin
      Now := (if Time < 0 then 0 elsif Time > 2 ** 62 then 2 ** 62 else Time);
   end Read_Monotonic;

   -------------------
   -- Open_Listener --
   -------------------

   procedure Open_Listener (Address : IPv4_Address; Port : Port_Number; Listener : out File_Descriptor) is begin
      Listener := Linux.Open_Listener (Address, Port);
   end Open_Listener;

   ------------------
   -- Create_Epoll --
   ------------------

   procedure Create_Epoll (Epoll : out File_Descriptor) is begin
      Epoll := Linux.Create_Epoll;
   end Create_Epoll;

   ----------
   -- Wait --
   ----------

   procedure Wait
     (Epoll : File_Descriptor; Into : in out Epoll_Event_Array; Timeout_Milliseconds : Integer; Count : out Natural)
   is begin
      Count := Natural'Min (Linux.Wait (Epoll, Into, Timeout_Milliseconds), Into'Last);
   end Wait;

   --------------------------
   -- Create_Event_Counter --
   --------------------------

   procedure Create_Event_Counter (Counter : out File_Descriptor) is begin
      Counter := Linux.Create_Event_Counter;
   end Create_Event_Counter;

   ------------
   -- Signal --
   ------------

   procedure Signal (Counter : File_Descriptor) is begin
      Linux.Signal (Counter);
   end Signal;

   -------------------------
   -- Unshare_Descriptors --
   -------------------------

   procedure Unshare_Descriptors (Done : out Boolean) is begin
      Done := Linux.Unshare_Descriptors;
   end Unshare_Descriptors;

   ---------------------------
   -- Raise_Open_File_Limit --
   ---------------------------

   procedure Raise_Open_File_Limit (Limit : out Natural) is begin
      Limit := Linux.Raise_Open_File_Limit;
   end Raise_Open_File_Limit;

   --------------------------
   -- Use_Batch_Scheduling --
   --------------------------

   procedure Use_Batch_Scheduling is begin
      Linux.Use_Batch_Scheduling;
   end Use_Batch_Scheduling;

   --------------
   -- Set_Nice --
   --------------

   procedure Set_Nice (Value : Integer) is begin
      Linux.Set_Nice (Value);
   end Set_Nice;

   -------------------------
   -- Ignore_Broken_Pipes --
   -------------------------

   procedure Ignore_Broken_Pipes is begin
      Linux.Ignore_Broken_Pipes;
   end Ignore_Broken_Pipes;

   ----------
   -- Stop --
   ----------

   procedure Stop (Code : Integer) is begin
      GNAT.OS_Lib.OS_Exit (Code);
   end Stop;

   -----------
   -- Sleep --
   -----------

   procedure Sleep (Duration_Milliseconds : Milliseconds) is begin
      if Duration_Milliseconds > 0 then
         delay Duration (Duration_Milliseconds) / 1000;
      end if;
   end Sleep;

   -----------------
   -- Environment --
   -----------------

   function Environment (Name : String) return Environment_Text is
      Value  : constant String := Linux.Environment (Name);
      Count  : constant Natural := Natural'Min (Value'Length, 65_536);
      Result : constant String (1 .. Count) := Value (Value'First .. Value'First + Count - 1);
   begin
      return Result;
   end Environment;

begin
   for Index in 0 .. Server.Reactors - 1 loop
      Counters (Index) := Linux.Create_Event_Counter;
   end loop;
end Socket_IO;
