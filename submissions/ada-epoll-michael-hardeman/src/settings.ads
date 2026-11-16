--  The configuration: DATABASE_URL, JWT_SECRET, HOST, PORT, READ_WINDOW_MS and STATS, read from the environment
--  as the program elaborates. Everything here is constant, so every task may read it without synchronization.
--
--  Proved free of run-time errors (SPARK silver), whatever the environment holds.
with Linux; use Linux;
with Socket_IO;

package Settings with SPARK_Mode, Elaborate_Body is

   function Or_Default (Value : Socket_IO.Environment_Text; Default : String) return Socket_IO.Environment_Text is
     (if Value'Length = 0 then Default else Value)
      with Pre => Default'First = 1 and then Default'Length <= 100;

   Secret       : constant Socket_IO.Environment_Text := Socket_IO.Environment ("JWT_SECRET");
   Database_Url : constant Socket_IO.Environment_Text :=
     Or_Default (Socket_IO.Environment ("DATABASE_URL"), "postgres://conduit:conduit@127.0.0.1:5432/conduit");
   Host         : constant Socket_IO.Environment_Text := Or_Default (Socket_IO.Environment ("HOST"), "127.0.0.1");
   Port_Image   : constant Socket_IO.Environment_Text := Or_Default (Socket_IO.Environment ("PORT"), "3000");
   Window_Image : constant Socket_IO.Environment_Text := Or_Default (Socket_IO.Environment ("READ_WINDOW_MS"), "10");
   Stats_Image  : constant Socket_IO.Environment_Text := Socket_IO.Environment ("STATS");

   --  Whether the configuration can be served; Problem says what is wrong when not.
   function Valid return Boolean;
   function Problem return String with Post => Problem'Result'Length <= 200;

   function Address return IPv4_Address;
   function Port return Port_Number;
   function Read_Window return Milliseconds with Post => Read_Window'Result in 0 .. 1000;

   --  Whether the lanes and hashers log stage statistics every 10 seconds (STATS=1).
   function Stats return Boolean is (Stats_Image = "1");

end Settings;
