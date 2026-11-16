with Bcrypt;
with Buffers; use Buffers;
with Effects;
with Http; use Http;
with Job_Queues; use Job_Queues;
with Jobs; use Jobs;
with Jwt;
with Linux;
with Model; use Model;
with Planner;
with Postgres; use Postgres;
with Render;
with Settings;
with Socket_IO;
with Stage_Stats;
with Sql;

package body Lanes with SPARK_Mode is

   use type Linux.Milliseconds;
   use type Sql.Statement_Access;

   ----------
   -- Open --
   ----------

   procedure Open (Lane : in out Connection)
      with Exceptional_Cases => (Connection_Error => True)
   is begin
      Connect (Lane, Settings.Database_Url);
      for Query of Sql.All_Statements loop
         if Query /= null then
            Prepare (Lane, Query.all);
         end if;
      end loop;
   end Open;

   ------------
   -- Reopen --
   ------------

   procedure Reopen (Lane : in out Connection) is begin
      loop
         Disconnect (Lane);
         begin
            Open (Lane);
            return;
         exception
            when Connection_Error =>
               Effects.Log ("postgres: " & Last_Failure (Lane) & "; retrying");
               Socket_IO.Sleep (1000);
         end;
      end loop;
   end Reopen;

   --  Used only by Check_Database, on the main task.
   Probe : Connection;

   --------------------
   -- Check_Database --
   --------------------

   procedure Check_Database (Reachable : out Boolean) is begin
      begin
         Open (Probe);
         Reachable := True;
      exception
         when Connection_Error =>
            Effects.Log ("postgres: " & Last_Failure (Probe));
            Reachable := False;
      end;

      Disconnect (Probe);
   end Check_Database;

   ---------
   -- Add --
   ---------

   procedure Add (Lane : in out Connection; User : User_Id) is begin
      Add_Parameter (Lane, Long_Long_Integer (User));
   end Add;

   ---------
   -- Add --
   ---------

   procedure Add (Lane : in out Connection; Comment : Comment_Id) is begin
      Add_Parameter (Lane, Long_Long_Integer (Comment));
   end Add;

   procedure Add (Lane : in out Connection; Text : String_Access) renames Add_Optional;

   ---------
   -- Key --
   ---------

   function Key (Lane : Connection; Rows : Statement_Result; Column : Positive := 1) return Long_Long_Integer is
     (Integer_Value (Lane, Field_At (Lane, Rows, 1, Column)));

   ---------------------------------------------------------------------------------------------------------------
   --  writes

   Max_Group          : constant := 128;   --  the most writes committed together
   Max_Job_Statements : constant := 3;

   subtype Statement_Total is Natural range 0 .. Max_Job_Statements;
   type Count_List is array (1 .. Max_Group) of Statement_Total;

   --------------
   -- Is_Write --
   --------------

   function Is_Write (Kind : Endpoint) return Boolean is
     (Kind in Register | Update_User | Follow | Unfollow | Create_Article | Update_Article | Delete_Article
            | Favorite | Unfavorite | Add_Comment | Delete_Comment);

   ---------------------
   -- Statement_Count --
   ---------------------

   --  Statements a write sends: one result each.
   function Statement_Count (Item : Job) return Statement_Total is
     (if not Is_Write (Item.Kind) then 0
      elsif Item.Kind = Create_Article and then Item.Article.Tags /= null and then Item.Article.Tags'Length > 0
      then 3 else 1);

   -----------------------------
   -- Encode_Write_Statements --
   -----------------------------

   --  A write's statements without a Sync: a group of writes shares one implicit transaction.
   procedure Encode_Write_Statements (Lane : in out Connection; Item : in out Job) is begin
      case Item.Kind is
         when Register =>
            Bind (Lane, Sql.Insert_User);
            Add (Lane, Item.Account.Username);
            Add (Lane, Item.Account.Email);
            Add (Lane, Item.Account.Password_Hash);
            Execute (Lane);
         when Update_User =>
            Bind (Lane, Sql.Update_User);
            Add (Lane, Item.Viewer);
            Add (Lane, Item.Account.Email);
            Add (Lane, Item.Account.Username);
            Add (Lane, Item.Account.Password_Hash);
            Add (Lane, Item.Account.Bio);
            Add (Lane, Item.Account.Image);
            Execute (Lane);
         when Follow | Unfollow =>
            Bind (Lane, (if Item.Kind = Follow then Sql.Follow else Sql.Unfollow));
            Add (Lane, Item.Viewer);
            Add (Lane, Item.Username);
            Execute (Lane);
         when Create_Article =>
            Bind (Lane, Sql.Insert_Article);
            Add (Lane, Item.Viewer);
            Add (Lane, Item.Article.Title);
            Add (Lane, Item.Article.Description);
            Add (Lane, Item.Article.Text);
            Execute (Lane);
            if Item.Article.Tags /= null and then Item.Article.Tags'Length > 0 then
               Bind (Lane, Sql.Insert_Tags);
               Add_Text_Array (Lane, Item.Article.Tags.all);
               Execute (Lane);
               Bind (Lane, Sql.Tag_Article);
               Add_Text_Array (Lane, Item.Article.Tags.all);
               Execute (Lane);
            end if;
         when Update_Article =>
            Bind (Lane, Sql.Update_Article);
            Add (Lane, Item.Slug);
            Add (Lane, Item.Article.Title);
            Add (Lane, Item.Article.Description);
            Add (Lane, Item.Article.Text);
            Add (Lane, Item.Viewer);
            Execute (Lane);
         when Delete_Article =>
            Bind (Lane, Sql.Delete_Article);
            Add (Lane, Item.Slug);
            Add (Lane, Item.Viewer);
            Execute (Lane);
         when Favorite | Unfavorite =>
            Bind (Lane, (if Item.Kind = Favorite then Sql.Favorite else Sql.Unfavorite));
            Add (Lane, Item.Viewer);
            Add (Lane, Item.Slug);
            Execute (Lane);
         when Add_Comment =>
            Bind (Lane, Sql.Insert_Comment);
            Add (Lane, Item.Slug);
            Add (Lane, Item.Viewer);
            Add (Lane, Item.Comment_Body);
            Execute (Lane);
         when Delete_Comment =>
            Bind (Lane, Sql.Delete_Comment);
            Add (Lane, Item.Comment);
            Add (Lane, Item.Slug);
            Add (Lane, Item.Viewer);
            Execute (Lane);
         when others =>
            null;   --  not a write: Statement_Count is 0
      end case;
   end Encode_Write_Statements;

   ------------------
   -- Answer_Write --
   ------------------

   --  The response to a write whose statements all succeeded, or Read_Back: the article it changed is to be read
   --  back by a read lane and rendered as the response, with Item.Status.
   procedure Answer_Write (Lane : Connection; Item : in out Job; Results : Result_Array; Read_Back : out Boolean)
      with Pre => Results'Length >= 1
   is
      First : constant Statement_Result := Results (Results'First);
      Now   : Unix_Seconds;

      ----------
      -- Back --
      ----------

      --  The changed article's id from Column, if it is one.
      procedure Back (Column : Positive; Status : Status_Code) with Pre => Item.Kind in Article_Endpoint is
         Id : constant Long_Long_Integer := Key (Lane, First, Column);
      begin
         if Id < 0 then
            Fail (Item, Internal_Server_Error);
         else
            Item.Changed := Article_Id (Id);
            Item.Status  := Status;
            Read_Back    := True;
         end if;
      end Back;

      -----------
      -- Owner --
      -----------

      function Owner (Column : Positive) return User_Id is
        (User_Id (Long_Long_Integer'Max (0, Key (Lane, First, Column))));
   begin
      Read_Back := False;
      Restart (Item.Response);

      if First.Row_Count = 0 and then Item.Kind not in Register | Create_Article then
         case Item.Kind is
            when Update_User => Fail (Item, Unauthorized);
            when others      => Fail (Item, Not_Found);
         end case;
         return;
      end if;

      case Item.Kind is
         when Register =>
            if Key (Lane, First) < 1 then
               Fail (Item, Internal_Server_Error);
            else
               Effects.Read_Clock (Now);
               Item.Status := Created;
               Render.User (Item.Response, Lane, First, Jwt.Sign (Known_User (Key (Lane, First)), Now));
            end if;
         when Update_User =>
            if Item.Account.Token = null then
               Fail (Item, Internal_Server_Error);
            else
               Render.User (Item.Response, Lane, First, Item.Account.Token.all);
            end if;
         when Follow | Unfollow =>
            Render.Profile (Item.Response, Lane, First, 1, Following => Item.Kind = Follow);
         when Create_Article =>
            Back (1, Created);
         when Update_Article | Delete_Article | Delete_Comment =>
            --  The statement returns (id, author_id) for an update, (author_id) for a delete.
            if Owner (if Item.Kind = Update_Article then 2 else 1) /= Item.Viewer then
               Fail (Item, Forbidden);
            elsif Item.Kind = Update_Article then
               Back (1, OK);
            else
               Item.Status := No_Content;
            end if;
         when Favorite | Unfavorite =>
            Back (1, OK);
         when Add_Comment =>
            Item.Status := Created;
            Append (Item.Response, "{""comment"":");
            Render.Comment (Item.Response, Lane, First, 1, Following => False);
            Append (Item.Response, "}");
         when others =>
            Fail (Item, Internal_Server_Error);
      end case;
   end Answer_Write;

   ------------------
   -- Finish_Write --
   ------------------

   --  Answer Item from its results, or pass it on to be read back: either way it is handed on.
   procedure Finish_Write (Lane : Connection; Item : in out Job_Access; Results : Result_Array)
      with Pre  => Item /= null and then Results'Length >= 1,
           Post => Item = null
   is
      Read_Back : Boolean := False;
   begin
      if (for all Result of Results => Result.Succeeded) then
         Answer_Write (Lane, Item.all, Results, Read_Back);
      else
         for Result of Results loop
            if not Result.Succeeded then
               Fail (This   => Item.all,
                     Status => (if Result.State = Unique_Violation then Unprocessable_Content
                                else Internal_Server_Error));
               exit;
            end if;
         end loop;
      end if;

      if Read_Back then
         Item.Stage := Reading_Back;
         Effects.Submit (Item);
      else
         Effects.Complete (Item);
      end if;
   end Finish_Write;

   ----------
   -- Move --
   ----------

   --  From's job moves to Into.
   procedure Move (Into, From : in out Job_Access)
      with Global => null,
           Pre    => Into = null,
           Post   => From = null is begin
      Into := From;
      From := null;
   end Move;

   -----------------
   -- Answer_Rest --
   -----------------

   --  Every job left in Batch is answered 500.
   procedure Answer_Rest (Batch : in out Job_List)
      with Post => (for all Index in Batch'Range => Batch (Index) = null)
   is begin
      for Index in Batch'Range loop
         pragma Loop_Invariant (for all Earlier in Batch'First .. Index - 1 => Batch (Earlier) = null);
         if Batch (Index) /= null then
            Fail (Batch (Index).all, Internal_Server_Error);
            Effects.Complete (Batch (Index));
         end if;
      end loop;
   end Answer_Rest;

   ---------------
   -- Fail_Lane --
   ---------------

   procedure Fail_Lane (Lane : in out Connection) is begin
      Effects.Log ("postgres (writes): " & Last_Failure (Lane));
      Discard_Unsent (Lane);
      Reopen (Lane);
   end Fail_Lane;

   subtype Group is Job_List (1 .. Max_Group);
   subtype Group_Results is Result_Array (1 .. Max_Job_Statements * Max_Group);

   -------------
   -- Counted --
   -------------

   --  Whether Counts holds each waiting job's statement count.
   function Counted (Batch : Group; Counts : Count_List) return Boolean is
     (for all Index in Batch'Range => (if Batch (Index) /= null then Counts (Index) > 0));

   --------------
   -- All_Null --
   --------------

   function All_Null (Batch : Job_List) return Boolean is (for all Index in Batch'Range => Batch (Index) = null);

   ------------------
   -- Encode_Group --
   ------------------

   --  Pipeline every write of the group; a job that is not a write cannot be sent and is answered at once.
   --  Total is the number of results to read back.
   procedure Encode_Group (Lane   : in out Connection;
                           Batch  : in out Group;
                           Counts : out Count_List;
                           Total  : out Natural)
      with Post => Counted (Batch, Counts)
                   and then Total <= Group_Results'Last
                   and then (if Total = 0 then All_Null (Batch))
   is begin
      Counts := [others => 0];
      Total  := 0;

      for Index in Batch'Range loop
         pragma Loop_Invariant (Total <= Max_Job_Statements * (Index - 1));
         pragma Loop_Invariant
           (for all Earlier in 1 .. Index - 1 => (if Batch (Earlier) /= null then Counts (Earlier) > 0));
         pragma Loop_Invariant (for all Earlier in 1 .. Index - 1 => (if Batch (Earlier) /= null then Total > 0));
         if Batch (Index) /= null then
            Counts (Index) := Statement_Count (Batch (Index).all);
            if Counts (Index) = 0 then
               Fail (Batch (Index).all, Internal_Server_Error);
               Effects.Complete (Batch (Index));
            else
               Encode_Write_Statements (Lane, Batch (Index).all);
               Total := Total + Counts (Index);
            end if;
         end if;
      end loop;
   end Encode_Group;

   pragma Warnings (GNATprove, Off, """Item"" is set by*", Reason => "each job is handed on; Item is done with it");

   ------------------
   -- Finish_Group --
   ------------------

   --  The group committed: answer each write from its results, in order.
   procedure Finish_Group (Lane : Connection; Batch : in out Group; Counts : Count_List; Results : Group_Results)
      with Pre  => Counted (Batch, Counts),
           Post => All_Null (Batch)
   is
      First : Positive := 1;
   begin
      for Index in Batch'Range loop
         pragma Loop_Invariant (First <= Max_Job_Statements * (Index - 1) + 1);
         pragma Loop_Invariant (for all Earlier in 1 .. Index - 1 => Batch (Earlier) = null);
         pragma Loop_Invariant
           (for all Later in Index .. Batch'Last => (if Batch (Later) /= null then Counts (Later) > 0));
         if Batch (Index) /= null then
            declare
               Item : Job_Access;
               Size : constant Statement_Total := Counts (Index);
            begin
               Move (Item, Batch (Index));
               if Item /= null then   --  always: Batch (Index) was not null
                  Finish_Write (Lane, Item, Results (First .. First + Size - 1));
               end if;
               First := First + Size;
            end;
         end if;
      end loop;
   end Finish_Group;

   -----------------
   -- Retry_Group --
   -----------------

   --  The group was rolled back: each write again on its own, so a bad one fails only itself. Sent is False
   --  when the connection failed (the writes not answered by then answer 500).
   procedure Retry_Group (Lane   : in out Connection;
                          Batch  : in out Group;
                          Counts : Count_List;
                          Results : in out Group_Results;
                          Sent : out Boolean)
      with Pre  => Counted (Batch, Counts),
           Post => All_Null (Batch)
   is
      Received : Boolean;
   begin
      for Index in Batch'Range loop
         if Batch (Index) /= null then
            Encode_Write_Statements (Lane, Batch (Index).all);
            Sync (Lane);
         end if;
      end loop;

      Try_Flush (Lane, Sent);

      for Index in Batch'Range loop
         pragma Loop_Invariant (for all Earlier in 1 .. Index - 1 => Batch (Earlier) = null);
         pragma Loop_Invariant
           (for all Later in Index .. Batch'Last => (if Batch (Later) /= null then Counts (Later) > 0));
         if Batch (Index) /= null then
            declare
               Item : Job_Access;
               Size : constant Statement_Total := Counts (Index);
            begin
               Move (Item, Batch (Index));
               Received := False;
               if Sent and then Size > 0 then
                  Try_Read_Results (Lane, Results (1 .. Size), Received);
               end if;

               if Item = null then
                  null;   --  never: Batch (Index) was not null
               elsif Received then
                  Finish_Write (Lane, Item, Results (1 .. Size));
               else
                  Sent := False;   --  the connection is gone: the rest fail too
                  Fail (Item.all, Internal_Server_Error);
                  Effects.Complete (Item);
               end if;
            end;
         end if;
      end loop;
   end Retry_Group;

   pragma Warnings (GNATprove, On, """Item"" is set by*");

   ----------------
   -- Write_Loop --
   ----------------

   --  Durable group commit: every write waiting is pipelined before one Sync, so the group is one implicit
   --  transaction with one WAL flush, and each response is released only after ReadyForQuery. If any
   --  statement fails, Postgres rolled the whole group back, and each write is sent again on its own.
   --  A group whose connection is lost has an unknown outcome: its writes answer 500 and are not retried.
   procedure Write_Loop is
      Lane     : Connection;
      Batch    : Group;
      Counts   : Count_List;
      Count    : Natural;
      Results  : Group_Results;
      Total    : Natural;
      Sent     : Boolean;
      Received : Boolean;
      Stats    : Stage_Stats.Counters;
      Queued   : Linux.Milliseconds;
      Taken    : Linux.Milliseconds;
      Done     : Linux.Milliseconds;
   begin
      Reopen (Lane);
      Socket_IO.Read_Monotonic (Done);
      Stage_Stats.Start (Stats, Done);

      loop
         pragma Loop_Invariant (All_Null (Batch));
         Write_Queue.Take (Batch, Count, Newest_First => False);
         pragma Assert (Count <= Max_Group);   --  the jobs are Batch (1 .. Count); the rest is null
         Queued := (if Batch (1) = null then 0 else Batch (1).Queued);
         Socket_IO.Read_Monotonic (Taken);

         Encode_Group (Lane, Batch, Counts, Total);
         if Total > 0 then
            Sync (Lane);
            Try_Flush (Lane, Sent);
            Received := False;
            if Sent then
               Try_Read_Results (Lane, Results (1 .. Total), Received);
            end if;

            if not Received then
               Answer_Rest (Batch);
               Fail_Lane (Lane);
            elsif (for all Result of Results (1 .. Total) => Result.Succeeded) then
               Finish_Group (Lane, Batch, Counts, Results);
            else
               Retry_Group (Lane, Batch, Counts, Results, Sent);
               if not Sent then
                  Fail_Lane (Lane);
               end if;
            end if;
         end if;

         Socket_IO.Read_Monotonic (Done);
         Stage_Stats.Add (Stats, Count, Queued, Taken, Done);
         Stage_Stats.Report (Stats, "write lane", Done);
      end loop;
   end Write_Loop;

   ---------------------------------------------------------------------------------------------------------------
   --  reads

   --  Read lanes take turns gathering: the lane holding the turn waits until the oldest read has been queued
   --  for Read_Window (or the queue is already long), takes everything waiting and lets the next lane gather
   --  while it answers its batch through the planner.
   Eager_Batch : constant := 256;   --  a queue this long is planned at once

   protected Gathering is
      entry Acquire;
      procedure Release;
   private
      Busy : Boolean := False;
   end Gathering;

   ---------------
   -- Gathering --
   ---------------

   protected body Gathering is

      -------------
      -- Acquire --
      -------------

      entry Acquire when not Busy is begin
         Busy := True;
      end Acquire;

      -------------
      -- Release --
      -------------

      procedure Release is begin
         Busy := False;
      end Release;
   end Gathering;

   ---------------
   -- Read_Loop --
   ---------------

   procedure Read_Loop is
      Lane   : Connection;
      Work   : Planner.Workspace;   --  the planner's sets, kept from batch to batch
      Batch  : Job_List (1 .. Planner.Max_Batch);
      Count  : Natural;
      Queued : Linux.Milliseconds;
      Now    : Linux.Milliseconds;
      Failed : Boolean;
      Length : Natural;
      Stats  : Stage_Stats.Counters;
      Taken  : Linux.Milliseconds;
      Done   : Linux.Milliseconds;
   begin
      Reopen (Lane);
      Socket_IO.Read_Monotonic (Done);
      Stage_Stats.Start (Stats, Done);

      loop
         pragma Loop_Invariant (for all Index in Batch'Range => Batch (Index) = null);
         Gathering.Acquire;
         Read_Queue.Wait_Oldest (Queued);

         Length := Read_Queue.Length;
         if Length < Eager_Batch and then Queued in 0 .. 2 ** 62 then
            Socket_IO.Read_Monotonic (Now);
            if Queued + Settings.Read_Window > Now then
               Socket_IO.Sleep (Queued + Settings.Read_Window - Now);
            end if;
         end if;

         Read_Queue.Take (Batch, Count, Newest_First => False);
         Gathering.Release;
         Socket_IO.Read_Monotonic (Taken);

         Planner.Execute (Work, Lane, Batch (1 .. Count), Failed);   --  logs why it failed
         if Failed then
            Discard_Unsent (Lane);
            Reopen (Lane);
         end if;

         Socket_IO.Read_Monotonic (Done);
         Stage_Stats.Add (Stats, Count, Queued, Taken, Done);
         Stage_Stats.Report (Stats, "read lane", Done);
      end loop;
   end Read_Loop;

   ---------------------------------------------------------------------------------------------------------------
   --  passwords

   ----------
   -- Hash --
   ----------

   --  Hash a new password (then on to Writing) or check a login's: either way the job is handed on.
   procedure Hash (Item : in out Job_Access) with Pre => Item /= null, Post => Item = null is
      Abandoned : Boolean;
      Random    : Bcrypt.Salt_Source;
   begin
      Effects.Check_Abandoned (Item, Abandoned);
      if Item.Kind not in Account_Endpoint or else Item.Account.Password = null then
         Fail (Item.all, Internal_Server_Error);
      elsif Item.Stage = Verifying then
         if Abandoned then
            null;   --  nobody is waiting for the answer
         elsif Item.Account.Password_Hash = null then
            Fail (Item.all, Internal_Server_Error);
         elsif not Bcrypt.Verify (Item.Account.Password.all, Item.Account.Password_Hash.all) then
            Fail (Item.all, Unauthorized);
         end if;
      elsif Item.Stage = Hashing then
         Socket_IO.Random_Bytes (Random);
         Free (Item.Account.Password_Hash);
         Item.Account.Password_Hash := new String'(Bcrypt.Hash (Item.Account.Password.all, Random));
         Item.Stage                 := Writing;
         Effects.Submit (Item);
         return;
      else
         Fail (Item.all, Internal_Server_Error);
      end if;

      Effects.Complete (Item);
   end Hash;

   ----------------
   -- Hash_Batch --
   ----------------

   --  Every job taken: the logins among them are checked together, any other job goes through Hash alone.
   procedure Hash_Batch (Taken : in out Job_List)
      with Pre  => Taken'Length <= Bcrypt.Max_Batch,
           Post => (for all Index in Taken'Range => Taken (Index) = null)
   is
      --  A login left at its default has no valid stored hash, so Verify_Batch passes over it at no cost.
      Logins : Bcrypt.Login_List (Taken'Range);
   begin
      for Index in Taken'Range loop
         if Taken (Index) /= null then
            declare
               Item      : Job_Access renames Taken (Index);
               Abandoned : Boolean;
            begin
               Effects.Check_Abandoned (Item, Abandoned);
               if not Abandoned
                 and then Item.Stage = Verifying
                 and then Item.Kind in Account_Endpoint
                 and then Item.Account.Password /= null
                 and then Item.Account.Password_Hash /= null
                 and then Item.Account.Password'Length <= Bcrypt.Max_Password_Length
                 and then Item.Account.Password_Hash'Length = Bcrypt.Hash_Length
               then
                  Logins (Index).Length                                := Item.Account.Password'Length;
                  Logins (Index).Password (1 .. Logins (Index).Length) := Item.Account.Password.all;
                  Logins (Index).Stored                                := Item.Account.Password_Hash.all;
               else
                  Hash (Item);
               end if;
            end;
         end if;
      end loop;

      Bcrypt.Verify_Batch (Logins);

      for Index in Taken'Range loop
         pragma Loop_Invariant (for all Earlier in Taken'First .. Index - 1 => Taken (Earlier) = null);
         if Taken (Index) /= null then
            if not Logins (Index).Match then
               Fail (Taken (Index).all, Unauthorized);
            end if;
            Effects.Complete (Taken (Index));
         end if;
      end loop;
   end Hash_Batch;

   ---------------------------------------------------------------------------------------------------------------
   --  the tasks

   --  Every task waits here until Start; hashers also take their number on the way.
   protected Gate is
      procedure Open;
      entry Wait_Open;
      procedure Number (Index : out Positive);
   private
      Opened : Boolean := False;
      Count  : Natural := 0;
   end Gate;

   ----------
   -- Gate --
   ----------

   pragma Warnings (GNATprove, Off, "statement has no effect", Reason => "an entry that only waits for its barrier");
   protected body Gate is

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

      ------------
      -- Number --
      ------------

      procedure Number (Index : out Positive) is begin
         Count := (if Count < Natural'Last then Count + 1 else Count);
         Index := Positive'Max (1, Count);
      end Number;
   end Gate;
   pragma Warnings (GNATprove, On, "statement has no effect");

   task type Read_Lane;
   task type Write_Lane;
   task type Hasher;

   Read_Lane_Tasks  : array (1 .. Read_Lanes) of Read_Lane;
   Write_Lane_Tasks : array (1 .. Write_Lanes) of Write_Lane;
   Hasher_Tasks     : array (1 .. Hashers) of Hasher;

   ---------------
   -- Read_Lane --
   ---------------

   task body Read_Lane is begin
      Socket_IO.Use_Batch_Scheduling;
      Gate.Wait_Open;
      Read_Loop;
   end Read_Lane;

   ----------------
   -- Write_Lane --
   ----------------

   task body Write_Lane is begin
      Socket_IO.Use_Batch_Scheduling;
      Gate.Wait_Open;
      Write_Loop;
   end Write_Lane;

   ------------
   -- Hasher --
   ------------

   --  The first hasher runs at normal priority so logins and sign-ups always make progress; the rest yield to
   --  the reactors and lanes.
   task body Hasher is
      Index  : Positive;
      Stats  : Stage_Stats.Counters;
      Queued : Linux.Milliseconds;
      Taken  : Linux.Milliseconds;
      Done   : Linux.Milliseconds;
   begin
      Gate.Number (Index);
      Socket_IO.Set_Nice (if Index = 1 then 0 else 10);
      Gate.Wait_Open;
      Socket_IO.Read_Monotonic (Done);
      Stage_Stats.Start (Stats, Done);

      loop
         declare
            Batch : Job_List (1 .. Bcrypt.Max_Batch);
            Count : Natural;
         begin
            --  Bcrypt falls behind first under overload. Newest first, a backlog costs the logins at its old end
            --  (they time out, their clients hang up, and their verify is skipped) instead of making every login
            --  wait out the whole backlog.
            Hash_Queue.Take (Batch, Count, Newest_First => True);
            pragma Assert (Count <= Batch'Length);   --  Batch itself says which jobs came
            Queued := Linux.Milliseconds'Last;
            for Item of Batch loop   --  taken newest first: the stats wait is the oldest one's
               if Item /= null then
                  Queued := Linux.Milliseconds'Min (Queued, Item.Queued);
               end if;
            end loop;
            Socket_IO.Read_Monotonic (Taken);
            pragma Warnings (GNATprove, Off, """Batch"" is set by*",
                             Reason => "the jobs are handed on; Batch is done with them");
            Hash_Batch (Batch);
            pragma Warnings (GNATprove, On, """Batch"" is set by*");
            Socket_IO.Read_Monotonic (Done);
            Stage_Stats.Add (Stats, Count, Queued, Taken, Done);
            Stage_Stats.Report (Stats, "hasher", Done);
         end;
      end loop;
   end Hasher;

   -----------
   -- Start --
   -----------

   procedure Start is begin
      Gate.Open;
   end Start;

end Lanes;
