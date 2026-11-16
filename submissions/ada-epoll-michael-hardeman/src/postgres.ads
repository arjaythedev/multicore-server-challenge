--  PostgreSQL v3 wire protocol client: SCRAM-SHA-256 login, named prepared statements, pipelined
--  Bind/Execute groups each closed by a Sync, binary parameters and results, results decoded in place from
--  the receive buffer. A connection belongs to one task and uses a blocking socket.
--
--  Proved free of run-time errors (SPARK silver), whatever the server sends. Failures of the connection or the
--  protocol raise Connection_Error, and only from the subprograms that say so. Building a pipeline is total: a
--  message that cannot be built (parameters not matching the statement, or past the buffer's limit) makes the
--  next Flush raise instead.
with Interfaces; use Interfaces;
with Buffers; use Buffers;
with Linux;
with Postgres_Wire;
with Socket_IO;

package Postgres with SPARK_Mode is

   Connection_Error : exception;

   type Type_Oid is new Unsigned_32;
   Int8_Oid       : constant Type_Oid := 20;
   Text_Oid       : constant Type_Oid := 25;
   Int8_Array_Oid : constant Type_Oid := 1016;
   Text_Array_Oid : constant Type_Oid := 1009;

   type Type_Oid_Array is array (Positive range <>) of Type_Oid;

   subtype Parameter_Total is Natural range 0 .. 2 ** 16 - 1;

   --  A named prepared statement and the types of its parameters $1 .. $Parameter_Count.
   type Statement (Name_Length, Text_Length : Positive; Parameter_Count : Parameter_Total) is record
      Name            : String (1 .. Name_Length);
      Text            : String (1 .. Text_Length);
      Parameter_Types : Type_Oid_Array (1 .. Parameter_Count);
   end record;

   function Define (Name, Text : String; Parameter_Types : Type_Oid_Array) return Statement is
     (Name_Length     => Name'Length,
      Text_Length     => Text'Length,
      Parameter_Count => Parameter_Types'Length,
      Name            => Name,
      Text            => Text,
      Parameter_Types => Parameter_Types)
      with Pre => Name'Length > 0 and then Text'Length > 0 and then Parameter_Types'Length <= Parameter_Total'Last;

   subtype Sql_State is String (1 .. 5);
   Unique_Violation : constant Sql_State := "23505";

   --  What one Execute produced. Rows are read with Field_At until the next Read_Results.
   type Statement_Result is record
      Succeeded    : Boolean := False;
      State        : Sql_State := "     ";   --  the error's SQLSTATE when not Succeeded
      First_Field  : Positive := 1;
      Row_Count    : Natural := 0;
      Column_Count : Natural := 0;
   end record;

   type Result_Array is array (Positive range <>) of Statement_Result;

   type Field is private;
   type Connection is limited private;

   procedure Connect (This : in out Connection; Url : String)
      with Pre               => Url'Last < Positive'Last,
           Global            => (In_Out => Socket_IO.Kernel),
           Exceptional_Cases => (Connection_Error => True);

   procedure Disconnect (This : in out Connection) with Global => (In_Out => Socket_IO.Kernel);

   --  Parse a named statement and wait for it (start-up only).
   procedure Prepare (This : in out Connection; Query : Statement)
      with Global => (In_Out => Socket_IO.Kernel), Exceptional_Cases => (Connection_Error => True);

   --  Building a pipeline: Bind, one Add per parameter in order, Execute; Sync closes a group.
   procedure Bind (This : in out Connection; Query : Statement);
   procedure Add_Parameter (This : in out Connection; Value : String);
   procedure Add_Parameter (This : in out Connection; Value : Long_Long_Integer);
   pragma Warnings (GNATprove, Off, """Value"" is not modified*", Reason => "callers hold String_Access");
   procedure Add_Optional (This : in out Connection; Value : String_Access);   --  null is SQL NULL
   pragma Warnings (GNATprove, On, """Value"" is not modified*");
   procedure Add_Text_Array (This : in out Connection; Items : String_List);

   --  An array parameter built in place: Begin_Array, then exactly Count Add_Element calls, then End_Array.
   procedure Begin_Array (This : in out Connection; Element_Type : Type_Oid; Count : Natural);
   procedure Add_Element (This : in out Connection; Value : String);
   procedure Add_Element (This : in out Connection; Value : Long_Long_Integer);
   procedure End_Array (This : in out Connection);

   procedure Execute (This : in out Connection);
   procedure Sync (This : in out Connection);

   --  Send everything built so far.
   procedure Flush (This : in out Connection)
      with Global => (In_Out => Socket_IO.Kernel), Exceptional_Cases => (Connection_Error => True);

   procedure Discard_Unsent (This : in out Connection);   --  after a Connection_Error

   --  Read one group's replies, up to its ReadyForQuery: one result per Execute, in order. A failed
   --  statement makes Postgres skip the rest of its group; those results stay not Succeeded. Rows of earlier
   --  groups stay readable when Keep_Earlier is set; otherwise they are dropped.
   procedure Read_Results (This : in out Connection; Results : out Result_Array; Keep_Earlier : Boolean := False)
      with Global => (In_Out => Socket_IO.Kernel), Exceptional_Cases => (Connection_Error => True);

   --  The same without exceptions, for proved callers: Sent and Received are False where those raise
   --  Connection_Error, and Last_Failure says why.
   procedure Try_Flush (This : in out Connection; Sent : out Boolean) with Global => (In_Out => Socket_IO.Kernel);
   procedure Try_Read_Results
     (This : in out Connection; Results : out Result_Array; Received : out Boolean; Keep_Earlier : Boolean := False)
      with Global => (In_Out => Socket_IO.Kernel);
   function Last_Failure (This : Connection) return String
      with Post => Last_Failure'Result'Length <= 200;

   --  Values. All are total: a field outside the result, or one whose bytes do not fit what is asked, reads as
   --  NULL, "", 0 or False.
   function Field_At (This : Connection; Result : Statement_Result; Row, Column : Positive) return Field with Inline;

   function Is_Null (Item : Field) return Boolean;
   function Text (This : Connection; Item : Field) return String;
   function Integer_Value (This : Connection; Item : Field) return Long_Long_Integer;
   function Boolean_Value (This : Connection; Item : Field) return Boolean;
   function Timestamp_Value (This : Connection; Item : Field) return Postgres_Timestamp;

   --  A one-dimensional array: its element count and its Index-th element.
   function Element_Count (This : Connection; Item : Field) return Natural;
   function Element (This : Connection; Item : Field; Index : Positive) return Field;

private

   type Field is new Postgres_Wire.Field;   --  a value in the receive buffer

   function Is_Null (Item : Field) return Boolean is (Postgres_Wire.Is_Null (Postgres_Wire.Field (Item)));

   type Field_Array is array (Positive range <>) of Field;
   type Field_Array_Access is access Field_Array;

   type Connection is limited record
      Socket             : Linux.File_Descriptor := Linux.No_Descriptor;
      Outgoing           : Buffer;
      Incoming           : Buffer;                               --  Data (Unread .. Length) is not parsed yet
      Unread             : Positive := 1;
      Fields             : Field_Array_Access;
      Field_Count        : Natural := 0;
      Message_Start      : Positive := 1;                        --  length word of the message being built
      Array_Start        : Positive := 1;                        --  length word of the array parameter being built
      Parameters_Missing : Natural := 0;
      Reason             : String (1 .. 200) := [others => ' ']; --  why the last Connection_Error was raised
      Reason_Length      : Natural range 0 .. 200 := 0;
   end record
   with Type_Invariant => Valid (Connection);

   function Valid (This : Connection) return Boolean is
     (Buffers.Valid (This.Outgoing) and then Buffers.Valid (This.Incoming)
      and then This.Unread <= This.Incoming.Length + 1
      and then (if This.Fields = null then This.Field_Count = 0
                else This.Fields'First = 1 and then This.Field_Count <= This.Fields'Last));

end Postgres;
