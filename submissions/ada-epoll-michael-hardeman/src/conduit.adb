--  Conduit (RealWorld) API server. Configuration: DATABASE_URL, JWT_SECRET, HOST, PORT, plus READ_WINDOW_MS
--  (Settings). The tasks are library-level objects (Server, Lanes): they already exist here, waiting for the
--  start below. They never end, so a failed start-up exits the process instead of returning.
with Effects;
with Job_Queues;
with Lanes;
with Server;
with Settings;
with Socket_IO;

procedure Conduit with SPARK_Mode is

   ----------
   -- Fail --
   ----------

   procedure Fail (Message : String) with Pre => Message'Length <= 1_000 is begin
      Effects.Log ("conduit: " & Message);
      Socket_IO.Stop (1);
   end Fail;

   Reachable : Boolean;
begin
   if not Settings.Valid then
      Fail (Settings.Problem);
   elsif not Job_Queues.Signals_Ready then
      Fail ("eventfd failed");
   else
      Socket_IO.Ignore_Broken_Pipes;
      Server.Ready; --  the reactors have their own descriptor tables before any Postgres connection opens

      Lanes.Check_Database (Reachable);
      if not Reachable then
         Fail ("cannot use DATABASE_URL");
      else
         Server.Start;
         Lanes.Start;
         Effects.Log ("conduit: listening on " & Settings.Host & ":" & Settings.Port_Image & ", reactors"
                      & Server.Reactors'Image & ", read lanes" & Lanes.Read_Lanes'Image & ", write lanes"
                      & Lanes.Write_Lanes'Image & ", hashers" & Lanes.Hashers'Image);
      end if;
   end if;
end Conduit;
