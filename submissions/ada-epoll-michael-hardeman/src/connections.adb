with Api;
with Http; use Http;
with Model;
with Socket_IO;

package body Connections with SPARK_Mode is

   First_Input_Capacity : constant := 4096;
   Max_Input_Capacity   : constant := Max_Head_Length + Max_Body_Length;

   ------------------
   -- Client_Valid --
   ------------------

   function Client_Valid (This : Client) return Boolean is
     (Valid (This.Input) and then Valid (This.Output) and then This.Output_Sent <= This.Output.Length);

   --------------------
   -- Output_Pending --
   --------------------

   function Output_Pending (This : Client) return Boolean is (This.Output_Sent < This.Output.Length)
   with Pre => Client_Valid (This);

   ------------
   -- Repair --
   ------------

   --  Never needed: every client stays valid. The check keeps the proofs local to one client.
   procedure Repair (This : in out Client) with Post => Client_Valid (This) is begin
      if not Client_Valid (This) then
         Restart (This.Input);
         Restart (This.Output);
         This.Output_Sent := 0;
      end if;
   end Repair;

   ------------------
   -- Close_Client --
   ------------------

   procedure Close_Client (This : in out Client; Socket : File_Descriptor)
   with Post => Client_Valid (This) and then not This.Open
   is begin
      if This.Open then
         if This.Busy then
            Effects.Abandon (This.In_Flight);
         end if;
         This.Generation := This.Generation + 1;
         Socket_IO.Close (Socket);
      end if;

      This.In_Flight := Effects.No_Job;
      This.Open      := False;
      This.Busy      := False;
      Free (This.Input);
      Free (This.Output);
      This.Output_Sent := 0;
   end Close_Client;

   ----------
   -- Send --
   ----------

   --  Write head and body together; whatever the socket does not take waits in Output for EPOLLOUT.
   procedure Send (This : in out Client; Socket : File_Descriptor; Head : String; Content : String)
   with
     Pre  => Client_Valid (This) and then Head'Length in 1 .. 1_024 and then Content'Length <= Max_Capacity,
     Post => Client_Valid (This) and then (if This.Open then This.Input.Length = This.Input.Length'Old)
   is
      Written : Integer;
      Error   : Error_Code;
   begin
      loop
         Socket_IO.Send_Pair (Socket, Head, Content, Written, Error);
         exit when Written >= 0 or else Error /= EINTR;
      end loop;

      if Written < 0 then
         if Error /= EAGAIN then
            Close_Client (This, Socket);
            return;
         end if;
         Written := 0;
      end if;

      if Written < Head'Length + Content'Length then
         Clear (This.Output);
         if Written < Head'Length then
            Append (This.Output, Head (Head'First + Written .. Head'Last));
            Append (This.Output, Content);
         else
            Append (This.Output, Content (Content'First + (Written - Head'Length) .. Content'Last));
         end if;
         This.Output_Sent := 0;
         if This.Output.Overflowed then
            Close_Client (This, Socket);
         end if;
      end if;
   end Send;

   -------------
   -- Respond --
   -------------

   procedure Respond (This : in out Client; Socket : File_Descriptor; Status : Status_Code; Content : String)
   with
     Pre  => Client_Valid (This) and then Content'Length <= Max_Capacity,
     Post => Client_Valid (This) and then (if This.Open then This.Input.Length = This.Input.Length'Old)
   is
      Closing : constant String := (if This.Close_After then "Connection: close" & CRLF else "");
   begin
      if Status = No_Content then
         Send (This, Socket, Status_Line (Status) & Closing & CRLF, "");
      else
         Send (This    => This,
               Socket  => Socket,
               Head    => Status_Line (Status) & "Content-Type: application/json" & CRLF
                          & "Content-Length:" & Decimal_Image (Long_Long_Integer (Content'Length)) & CRLF
                          & Closing & CRLF,
               Content => Content);
      end if;

      if This.Open and then This.Close_After and then not Output_Pending (This) then
         Close_Client (This, Socket);
      end if;
   end Respond;

   -------------------
   -- Respond_Error --
   -------------------

   procedure Respond_Error (This : in out Client; Socket : File_Descriptor; Status : Status_Code)
   with
     Pre  => Client_Valid (This),
     Post => Client_Valid (This) and then (if This.Open then This.Input.Length = This.Input.Length'Old)
   is begin
      Respond (This, Socket, Status, Error_Body (Status));
   end Respond_Error;

   -------------
   -- Process --
   -------------

   --  Handle the requests in the input buffer while the connection is idle.
   procedure Process
     (Owner : Reactor; This : in out Client; Document : in out Json.Document; Socket : File_Descriptor)
   with
     Pre  => Client_Valid (This) and then Document.Text_Capacity < Positive'Last,
     Post => Client_Valid (This)
   is
      Now : Model.Unix_Seconds;
   begin
      while This.Open and then not This.Busy and then not Output_Pending (This) and then This.Input.Length > 0
      loop
         pragma Loop_Invariant (Client_Valid (This) and then This.Input.Data /= null);
         declare
            Head : constant Request_Head := Parse_Head (This.Input.Data (1 .. This.Input.Length));
         begin
            case Head.Outcome is
               when Incomplete =>
                  return;
               when Invalid =>
                  This.Close_After := True;
                  Respond_Error (This, Socket, Head.Status);
                  return;
               when Complete =>
                  null;
            end case;

            if Head.Body_Length > This.Input.Length - Head.Head_Length then
               Reserve (This.Input, Head.Body_Length - (This.Input.Length - Head.Head_Length));   --  room for the rest
               return;
            end if;

            declare
               Total  : constant Positive := Head.Head_Length + Head.Body_Length;
               Routed : Api.Routing;
            begin
               This.Close_After := not Head.Keep_Alive;
               if Within (Head.Path, This.Input.Data (1 .. Total))
                 and then Within (Head.Query, This.Input.Data (1 .. Total))
                 and then Within (Head.Authorization, This.Input.Data (1 .. Total))
               then
                  Effects.Read_Clock (Now);
                  Api.Route (This.Input.Data (1 .. Total), Head, Now, Document, Routed);
               else
                  Routed := (Accepted => False, Status => Internal_Server_Error);   --  never: the spans are in the head
               end if;

               if Routed.Accepted then
                  Routed.Work.Reply := (Reactor => Owner.Id, Client => Socket, Generation => This.Generation);
                  pragma Warnings
                    (GNATprove, Off, """Routed.Work"" is set by ""Submit_Tracked"" but not used after the call",
                     Reason => "the job moves to another task; null is left behind");
                  Effects.Submit_Tracked (Routed.Work, This.In_Flight);
                  pragma Warnings
                    (GNATprove, On, """Routed.Work"" is set by ""Submit_Tracked"" but not used after the call");
                  This.Busy := True;
               else
                  Respond_Error (This, Socket, Routed.Status);
               end if;

               if This.Open then
                  Consume (This.Input, Total);
                  if This.Input.Length = 0 then
                     Free (This.Input);
                  end if;
               end if;
            end;
         end;
      end loop;
   end Process;

   -----------------
   -- On_Readable --
   -----------------

   procedure On_Readable
     (Owner : Reactor; This : in out Client; Document : in out Json.Document; Socket : File_Descriptor)
   with
     Pre  => Client_Valid (This) and then Document.Text_Capacity < Positive'Last,
     Post => Client_Valid (This)
   is
      Got   : Integer;
      Error : Error_Code;
   begin
      while This.Open loop
         pragma Loop_Invariant (Client_Valid (This));
         if Capacity (This.Input) = 0 then
            Allocate (This.Input, First_Input_Capacity);
         elsif This.Input.Length = Capacity (This.Input) then
            exit when This.Busy or else Capacity (This.Input) >= Max_Input_Capacity;
            Reserve (This.Input, Capacity (This.Input));   --  double
         end if;
         exit when This.Input.Length >= Capacity (This.Input);

         Socket_IO.Receive (Socket, This.Input.Data (This.Input.Length + 1 .. Capacity (This.Input)), Got, Error);
         if Got > 0 then
            Extend (This.Input, Got);
            Process (Owner, This, Document, Socket);
         elsif Got = 0 then
            Close_Client (This, Socket);
            return;
         elsif Error = EAGAIN then
            exit;
         elsif Error /= EINTR then
            Close_Client (This, Socket);
            return;
         end if;
      end loop;

      if This.Open and then This.Input.Length = 0 then
         Free (This.Input);
      end if;
   end On_Readable;

   -----------------
   -- On_Writable --
   -----------------

   procedure On_Writable
     (Owner : Reactor; This : in out Client; Document : in out Json.Document; Socket : File_Descriptor)
   with
     Pre  => Client_Valid (This) and then Document.Text_Capacity < Positive'Last,
     Post => Client_Valid (This)
   is
      Sent  : Integer;
      Error : Error_Code;
   begin
      while This.Open and then Output_Pending (This) loop
         pragma Loop_Invariant (Client_Valid (This) and then This.Output.Data /= null);
         Socket_IO.Send (Socket, This.Output.Data (This.Output_Sent + 1 .. This.Output.Length), Sent, Error);
         if Sent > 0 then
            This.Output_Sent := This.Output_Sent + Sent;
         elsif Sent < 0 and then Error = EINTR then
            null;
         elsif Sent < 0 and then Error = EAGAIN then
            return;
         else
            Close_Client (This, Socket);
            return;
         end if;
      end loop;

      if This.Open then
         Free (This.Output);
         This.Output_Sent := 0;
         if This.Close_After then
            Close_Client (This, Socket);
         else
            Process (Owner, This, Document, Socket);
            On_Readable (Owner, This, Document, Socket);
         end if;
      end if;
   end On_Writable;

   --------------------
   -- On_Completions --
   --------------------

   procedure On_Completions (Owner : Reactor; Clients : in out Client_Table; Document : in out Json.Document)
   with Pre => Document.Text_Capacity < Positive'Last
   is
      Item : Job_Access;
   begin
      Socket_IO.Drain (Owner.Completed);
      Effects.Take_Completed (Owner.Id, Item);

      while Item /= null loop
         declare
            Next   : constant Job_Access := Item.Next;
            Socket : constant File_Descriptor := Item.Reply.Client;
         begin
            if Socket in Clients'Range then
               Repair (Clients (Socket));
               if Clients (Socket).Open and then Clients (Socket).Busy
                 and then Clients (Socket).Generation = Item.Reply.Generation
               then
                  Clients (Socket).Busy      := False;
                  Clients (Socket).In_Flight := Effects.No_Job;

                  if Item.Response.Overflowed or else not Valid (Item.Response) then
                     Respond_Error (Clients (Socket), Socket, Internal_Server_Error);
                  elsif Item.Response.Data = null then
                     Respond (Clients (Socket), Socket, Item.Status, "");
                  else
                     Respond (This    => Clients (Socket),
                              Socket  => Socket,
                              Status  => Item.Status,
                              Content => Item.Response.Data (1 .. Item.Response.Length));
                  end if;

                  if Clients (Socket).Open and then not Output_Pending (Clients (Socket)) then
                     Process (Owner, Clients (Socket), Document, Socket);
                     On_Readable (Owner, Clients (Socket), Document, Socket);
                  end if;
               end if;   --  otherwise the client went away meanwhile
            end if;

            --  Free requires Item.Next to be null (Next already holds it). Flow analysis sees neither that use of
            --  the assignment nor the memory Free releases.
            pragma Warnings (GNATprove, Off, "unused assignment", Reason => "Free's precondition reads it");
            pragma Warnings (GNATprove, Off, "statement has no effect", Reason => "releases memory");
            pragma Warnings
              (GNATprove, Off, """Item"" is set by ""Free"" but not used after the call", Reason => "releases memory");
            Item.Next := null;
            Free (Item);
            pragma Warnings (GNATprove, On, """Item"" is set by ""Free"" but not used after the call");
            pragma Warnings (GNATprove, On, "statement has no effect");
            pragma Warnings (GNATprove, On, "unused assignment");
            Item := Next;
         end;
      end loop;
   end On_Completions;

   ----------------
   -- Accept_All --
   ----------------

   procedure Accept_All (Owner : in out Reactor; Clients : in out Client_Table) is
      Socket : File_Descriptor;
      Error  : Error_Code;
      Now    : Milliseconds;
   begin
      loop
         Socket_IO.Accept_Client (Owner.Listener, Socket, Error);
         if Socket = No_Descriptor then
            if Error in EMFILE | ENFILE | ENOBUFS | ENOMEM then
               --  out of descriptors: stop listening for 100 ms instead of spinning
               Socket_IO.Unwatch (Owner.Epoll, Owner.Listener);
               Socket_IO.Read_Monotonic (Now);
               Owner.Paused_Until := Now + 100;
            end if;
            return;
         elsif Socket not in Clients'Range then   --  beyond the table: refuse
            Socket_IO.Close (Socket);
         else
            Socket_IO.Set_No_Delay (Socket);
            Clients (Socket).Open        := True;
            Clients (Socket).Busy        := False;
            Clients (Socket).Close_After := False;
            Clients (Socket).In_Flight   := Effects.No_Job;
            Clients (Socket).Generation  := Clients (Socket).Generation + 1;
            Clients (Socket).Output_Sent := 0;
            Restart (Clients (Socket).Input);
            Restart (Clients (Socket).Output);
            Socket_IO.Watch (Owner.Epoll, Socket, EPOLLIN or EPOLLOUT or EPOLLRDHUP or EPOLLET);
         end if;
      end loop;
   end Accept_All;

   ---------------------
   -- On_Client_Event --
   ---------------------

   procedure On_Client_Event
     (Owner : Reactor; This : in out Client; Document : in out Json.Document; Socket : File_Descriptor;
      Events : Event_Mask)
   with
     Pre  => Client_Valid (This) and then Document.Text_Capacity < Positive'Last,
     Post => Client_Valid (This)
   is begin
      if (Events and (EPOLLERR or EPOLLHUP)) /= 0 then
         Close_Client (This, Socket);
         return;
      end if;

      if (Events and EPOLLIN) /= 0 then
         On_Readable (Owner, This, Document, Socket);
      end if;

      if This.Open and then (Events and EPOLLOUT) /= 0 and then Output_Pending (This) then
         On_Writable (Owner, This, Document, Socket);
      end if;

      if This.Open and then (Events and EPOLLRDHUP) /= 0 and then not This.Busy and then not Output_Pending (This)
      then
         Close_Client (This, Socket);   --  the peer finished sending and nothing is owed
      end if;
   end On_Client_Event;

   --------------
   -- On_Event --
   --------------

   procedure On_Event
     (This     : in out Reactor;
      Clients  : in out Client_Table;
      Document : in out Json.Document;
      Socket   : File_Descriptor;
      Events   : Event_Mask)
   is begin
      if Socket = This.Listener then
         Accept_All (This, Clients);
      elsif Socket = This.Completed then
         On_Completions (This, Clients, Document);
      elsif Socket in Clients'Range then
         Repair (Clients (Socket));
         if Clients (Socket).Open then
            On_Client_Event (This, Clients (Socket), Document, Socket, Events);
         end if;
      end if;
   end On_Event;

   ----------------------
   -- Resume_Listening --
   ----------------------

   procedure Resume_Listening (This : in out Reactor) is
      Now : Milliseconds;
   begin
      if This.Paused_Until > 0 then
         Socket_IO.Read_Monotonic (Now);
         if Now >= This.Paused_Until then
            This.Paused_Until := 0;
            Socket_IO.Watch (This.Epoll, This.Listener, EPOLLIN);
         end if;
      end if;
   end Resume_Listening;

end Connections;
