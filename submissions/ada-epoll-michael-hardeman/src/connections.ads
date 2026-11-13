--  What a reactor does with an epoll event: accept connections, read requests, route them, write responses,
--  and send back the jobs other tasks finished. The reactor task (Server) only waits on epoll and passes each
--  event here.
--
--  Proved free of run-time errors (SPARK silver) whatever the peer sends and whatever the kernel reports, and
--  to hand every routed job on and free every finished one.
with Buffers; use Buffers;
with Effects;
with Jobs; use Jobs;
with Json;
with Linux; use Linux;

package Connections with SPARK_Mode is

   --  A client connection, found by its descriptor.
   type Client is record
      Open        : Boolean := False;
      Busy        : Boolean := False;                     --  a job of this connection is in flight
      Close_After : Boolean := False;                     --  close once the current response is out
      Generation  : Jobs.Generation := 0;
      In_Flight   : Effects.Job_Handle := Effects.No_Job; --  the job while Busy
      Input       : Buffer;                               --  received bytes not yet handled
      Output      : Buffer;                               --  a response the socket did not take at once
      Output_Sent : Natural := 0;                         --  how much of Output the socket has taken
   end record;

   type Client_Table is array (File_Descriptor range <>) of Client;

   --  A reactor's own descriptors.
   type Reactor is record
      Id           : Reactor_Id := 0;
      Epoll        : File_Descriptor := No_Descriptor;
      Listener     : File_Descriptor := No_Descriptor;
      Completed    : File_Descriptor := No_Descriptor; --  signalled when other tasks finish its jobs
      Paused_Until : Milliseconds := 0;                --  0: listening
   end record;

   --  Handle one epoll event on Socket.
   procedure On_Event
     (This     : in out Reactor;
      Clients  : in out Client_Table;
      Document : in out Json.Document;
      Socket   : File_Descriptor;
      Events   : Event_Mask)
   with Pre => Document.Text_Capacity < Positive'Last;

   --  Listen again once a pause for want of descriptors is over.
   procedure Resume_Listening (This : in out Reactor);

end Connections;
