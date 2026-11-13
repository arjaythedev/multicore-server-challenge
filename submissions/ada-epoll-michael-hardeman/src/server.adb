with Interfaces; use Interfaces;
with Connections;
with Effects;
with Http;
with Job_Queues;
with Json;
with Linux; use Linux;
with Settings;
with Socket_IO;

package body Server with SPARK_Mode is

   --  Every reactor gives itself a descriptor table of its own before any of them opens a socket, so no table
   --  holds a copy of another reactor's clients (a copy would keep a closed client's connection open). Each
   --  takes the next Id as it arrives, then waits until Start lets them listen.
   protected Gate is
      procedure Arrive (Id : out Jobs.Reactor_Id);
      entry Wait_Unshared;
      procedure Open;
      entry Wait_Open;
   private
      Arrived : Natural := 0;
      Opened  : Boolean := False;
   end Gate;

   ----------
   -- Gate --
   ----------

   pragma Warnings (GNATprove, Off, "statement has no effect", Reason => "entries that only wait for their barrier");
   protected body Gate is

      ------------
      -- Arrive --
      ------------

      procedure Arrive (Id : out Jobs.Reactor_Id) is begin
         Id      := Jobs.Reactor_Id (Natural'Min (Arrived, Natural (Last_Reactor)));
         Arrived := (if Arrived < Reactors then Arrived + 1 else Arrived);
      end Arrive;

      -------------------
      -- Wait_Unshared --
      -------------------

      entry Wait_Unshared when Arrived = Reactors is begin
         null;
      end Wait_Unshared;

      ----------
      -- Open --
      ----------

      procedure Open is begin
         Opened := True;
      end Open;

      ---------------
      -- Wait_Open --
      ---------------

      entry Wait_Open when Opened is begin
         null;
      end Wait_Open;
   end Gate;
   pragma Warnings (GNATprove, On, "statement has no effect");

   type Client_Table_Access is access Connections.Client_Table;
   type Document_Access is access Json.Document;

   --  The most clients one reactor's table has room for, however high the open file limit is.
   Max_Clients : constant := 1_100_000;

   --  Each reactor waits on its own epoll set and hands every event to Connections.
   task type Reactor;

   Reactor_Tasks : array (Jobs.Reactor_Id range 0 .. Last_Reactor) of Reactor;

   -------------
   -- Reactor --
   -------------

   task body Reactor is
      Id       : Jobs.Reactor_Id;
      State    : Connections.Reactor;
      Unshared : Boolean;
      Limit    : Natural;
      Clients  : Client_Table_Access;
      Document : constant Document_Access := new Json.Document (Node_Capacity => 65_536,
                                                                Text_Capacity => Http.Max_Body_Length + 16);
      Events   : Epoll_Event_Array (1 .. 512) := [others => (Events => 0, Data => 0)];
      Ready    : Natural;
   begin
      Socket_IO.Use_Batch_Scheduling;
      Socket_IO.Set_Nice (5);
      Socket_IO.Unshare_Descriptors (Unshared);

      if not Unshared then
         Effects.Log ("reactor: unshare (CLONE_FILES) refused, sharing the process descriptor table");
      end if;

      Gate.Arrive (Id);
      Gate.Wait_Open;

      --  Clients is indexed by descriptor, and every descriptor is below Limit (with 64 to spare).
      pragma Warnings (GNATprove, Off, """Limit"" is set by*",
                       Reason => "flow analysis does not count an allocator's bounds as a use");
      Socket_IO.Raise_Open_File_Limit (Limit);
      pragma Warnings (GNATprove, On, """Limit"" is set by*");
      Clients := new Connections.Client_Table (0 .. File_Descriptor (Natural'Min (Limit, Max_Clients - 64) + 63));
      State   := (Id => Id, Completed => Job_Queues.Completion_Signal (Id), others => <>);

      Socket_IO.Create_Epoll (State.Epoll);
      Socket_IO.Open_Listener (Settings.Address, Settings.Port, State.Listener);

      if State.Listener = No_Descriptor or else State.Epoll = No_Descriptor then
         Effects.Log ("reactor: cannot listen on port " & Settings.Port_Image);
         Socket_IO.Stop (1);
      end if;

      Socket_IO.Watch (State.Epoll, State.Listener,  EPOLLIN);
      Socket_IO.Watch (State.Epoll, State.Completed, EPOLLIN);

      loop
         Socket_IO.Wait (Epoll                => State.Epoll,
                         Into                 => Events,
                         Count                => Ready,
                         Timeout_Milliseconds => (if State.Paused_Until > 0 then 100 else -1));

         Connections.Resume_Listening (State);
         for Index in 1 .. Ready loop
            if Events (Index).Data <= Unsigned_64 (File_Descriptor'Last) then
               Connections.On_Event (This     => State,
                                     Clients  => Clients.all,
                                     Document => Document.all,
                                     Socket   => File_Descriptor (Events (Index).Data),
                                     Events   => Events (Index).Events);
            end if;
         end loop;
      end loop;
   end Reactor;

   -----------
   -- Ready --
   -----------

   procedure Ready is begin
      Gate.Wait_Unshared;
   end Ready;

   -----------
   -- Start --
   -----------

   procedure Start is begin
      Gate.Open;
   end Start;

end Server;
