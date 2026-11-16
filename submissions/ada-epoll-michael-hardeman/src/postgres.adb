with Ada.Unchecked_Deallocation;
with Base64;
with Sha256;

package body Postgres with SPARK_Mode is

   use type Linux.File_Descriptor;
   use type Linux.Error_Code;

   procedure Free is new Ada.Unchecked_Deallocation (Field_Array, Field_Array_Access);

   Read_Size   : constant := 16_384;
   Max_Message : constant := 2 ** 28;   --  larger replies are refused: no statement here produces one
   Max_Fields  : constant := 2 ** 26;

   --  Message types.
   Authentication   : constant Character := 'R';
   Error_Response   : constant Character := 'E';
   Ready_For_Query  : constant Character := 'Z';
   Data_Row         : constant Character := 'D';
   Command_Complete : constant Character := 'C';
   Empty_Query      : constant Character := 'I';
   Password_Message : constant Character := 'p';
   Parse_Message    : constant Character := 'P';
   Bind_Message     : constant Character := 'B';
   Execute_Message  : constant Character := 'E';
   Sync_Message     : constant Character := 'S';

   Binary_Format : constant Unsigned_16 := 1;

   ----------
   -- Clip --
   ----------

   --  At most the first 200 characters of Text, for an error message.
   function Clip (Text : String) return String is
     (if Text'Length <= 200 then Text else Text (Text'First .. Text'First + 199))
      with Post => Clip'Result'Length <= 200;

   ----------
   -- Fail --
   ----------

   --  Record why the connection failed, then raise Connection_Error.
   procedure Fail (This : in out Connection; Message : String)
      with No_Return,
           Pre               => Valid (This),
           Global            => null,
           Exceptional_Cases => (Connection_Error => Valid (This))
   is
      Kept : constant Natural := Natural'Min (Message'Length, This.Reason'Length);
   begin
      This.Reason (1 .. Kept) := Message (Message'First .. Message'First - 1 + Kept);
      This.Reason_Length      := Kept;
      raise Connection_Error with Message;
   end Fail;

   ---------------------------------------------------------------------------------------------------------------
   --  socket I/O

   ---------------
   -- Write_All --
   ---------------

   procedure Write_All (This : in out Connection)
      with Pre               => Valid (This),
           Post              => Valid (This) and then This.Unread = This.Unread'Old,
           Global            => (In_Out => Socket_IO.Kernel),
           Exceptional_Cases => (Connection_Error => Valid (This))
   is
      Sent  : Natural := 0;
      Count : Integer;
      Error : Linux.Error_Code;
   begin
      if This.Outgoing.Overflowed then
         Fail (This, "message could not be built");
      end if;

      while Sent < This.Outgoing.Length loop
         pragma Loop_Invariant (Valid (This) and then This.Unread = This.Unread'Loop_Entry);
         Socket_IO.Send (This.Socket, This.Outgoing.Data (Sent + 1 .. This.Outgoing.Length), Count, Error);
         if Count >= 0 then
            Sent := Sent + Count;
         elsif Error /= Linux.EINTR then
            Fail (This, "send failed");
         end if;
      end loop;

      Clear (This.Outgoing);
      end Write_All;

   ----------
   -- Need --
   ----------

   --  Read until Count unparsed bytes are buffered.
   procedure Need (This : in out Connection; Count : Positive)
      with Pre               => Valid (This) and then Count <= Max_Message,
           Post              => Valid (This) and then This.Unread = This.Unread'Old
                                and then This.Incoming.Length - This.Unread + 1 >= Count,
           Global            => (In_Out => Socket_IO.Kernel),
           Exceptional_Cases => (Connection_Error => Valid (This))
   is
      Got   : Integer;
      Error : Linux.Error_Code;
   begin
      if This.Unread > Buffers.Max_Capacity - 2 * Count - Read_Size then
         Fail (This, "reply too large");
      end if;

      while This.Incoming.Length - This.Unread + 1 < Count loop
         pragma Loop_Invariant (Valid (This) and then This.Unread = This.Unread'Loop_Entry);
         Reserve (This.Incoming, Natural'Max (Count, Read_Size));
         Socket_IO.Receive (Socket => This.Socket,
                            Into   => This.Incoming.Data (This.Incoming.Length + 1 .. Capacity (This.Incoming)),
                            Count  => Got,
                            Error  => Error);
         if Got > 0 then
            Extend (This.Incoming, Got);
         elsif Got = 0 then
            Fail (This, "connection closed by server");
         elsif Error /= Linux.EINTR then
            Fail (This, "recv failed");
         end if;
      end loop;
   end Need;

   -------------
   -- Compact --
   -------------

   --  Drop the parsed bytes from the front of the receive buffer.
   procedure Compact (This : in out Connection)
   with Pre => Valid (This), Post => Valid (This) and then This.Unread = 1
   is begin
      Consume (This.Incoming, This.Unread - 1);
      This.Unread := 1;
   end Compact;

   ----------
   -- Wire --
   ----------

   function Wire (Item : Field) return Postgres_Wire.Field is (Postgres_Wire.Field (Item)) with Inline;

   type Message is record
      Kind  : Character;
      First : Positive;   --  the content, after the type and length
      Last  : Natural;
   end record;

   --------------
   -- Received --
   --------------

   --  Whether Reply is a message in the receive buffer.
   function Received (This : Connection; Reply : Message) return Boolean is
     (Reply.Last <= This.Incoming.Length and then Reply.First - 1 <= Reply.Last);

   ------------------
   -- Next_Message --
   ------------------

   procedure Next_Message (This : in out Connection; Reply : out Message)
      with Pre               => Valid (This),
           Post              => Valid (This) and then Received (This, Reply),
           Global            => (In_Out => Socket_IO.Kernel),
           Exceptional_Cases => (Connection_Error => Valid (This))
   is
      Length : Unsigned_32;
   begin
      Reply := (Kind => ASCII.NUL, First => 1, Last => 0);
      Need (This, 5);

      Length := Postgres_Wire.Word (This.Incoming.Data (1 .. This.Incoming.Length), This.Unread + 1);
      if Length < 4 or else Length >= Max_Message then
         Fail (This, "bad message length");
      end if;

      Need (This, 1 + Natural (Length));
      Reply := (Kind  => This.Incoming.Data (This.Unread),
                First => This.Unread + 5,
                Last  => This.Unread + Natural (Length));
      This.Unread := This.Unread + 1 + Natural (Length);
   end Next_Message;

   ----------------
   -- First_Word --
   ----------------

   --  The first word of a message's content (an Authentication message's request code); all ones when the
   --  message is too short to have one.
   function First_Word (This : Connection; Reply : Message) return Unsigned_32 is
     (if Reply.First <= Reply.Last - 3
      then Postgres_Wire.Word (This.Incoming.Data (1 .. This.Incoming.Length), Reply.First)
      else Unsigned_32'Last)
      with Pre => Valid (This) and then Received (This, Reply);

   -----------------
   -- Error_Field --
   -----------------

   --  One field of an ErrorResponse: 'M' the message, 'C' the SQLSTATE.
   function Error_Field (This : Connection; Error : Message; Code : Character) return String is
     (if This.Incoming.Data = null then ""
      else Postgres_Wire.Error_Field (This.Incoming.Data (1 .. This.Incoming.Length), Error.First, Error.Last, Code))
      with Pre => Valid (This) and then Received (This, Error);

   ---------------------------------------------------------------------------------------------------------------
   --  message building: total, a message that cannot be built marks the buffer unsendable

   -----------
   -- Patch --
   -----------

   --  Write a length word built after the fact; Position is where it was reserved.
   procedure Patch (Into : in out Buffer; Position : Positive; Value : Unsigned_32)
      with Pre => Buffers.Valid (Into), Post => Buffers.Valid (Into) and then Into.Length = Into.Length'Old
   is begin
      if Position <= Into.Length - 3 then
         Overwrite_Big_Endian (Into, Position, Value);
      else
         Into.Overflowed := True;
      end if;
   end Patch;

   ----------------
   -- Unsendable --
   ----------------

   procedure Unsendable (This : in out Connection)
      with Pre => Valid (This), Post => Valid (This) and then This.Unread = This.Unread'Old
   is begin
      This.Outgoing.Overflowed := True;
   end Unsendable;

   -------------------
   -- Begin_Message --
   -------------------

   procedure Begin_Message (This : in out Connection; Kind : Character)
      with Pre => Valid (This), Post => Valid (This) and then This.Unread = This.Unread'Old
   is begin
      Append (This.Outgoing, Kind);
      This.Message_Start := This.Outgoing.Length + 1;
      Append_Big_Endian (This.Outgoing, Unsigned_32'(0));   --  the length, set by End_Message
   end Begin_Message;

   -----------------
   -- End_Message --
   -----------------

   procedure End_Message (This : in out Connection)
      with Pre => Valid (This), Post => Valid (This) and then This.Unread = This.Unread'Old
   is begin
      if This.Message_Start <= This.Outgoing.Length then
         Patch (This.Outgoing, This.Message_Start, Unsigned_32 (This.Outgoing.Length - This.Message_Start + 1));
      else
         Unsendable (This);
      end if;
   end End_Message;

   ---------------------
   -- Append_C_String --
   ---------------------

   procedure Append_C_String (This : in out Connection; Text : String)
      with Pre => Valid (This), Post => Valid (This) and then This.Unread = This.Unread'Old
   is begin
      Append (This.Outgoing, Text);
      Append (This.Outgoing, ASCII.NUL);
   end Append_C_String;

   ---------------------------------------------------------------------------------------------------------------
   --  connecting

   --------------
   -- Index_Of --
   --------------

   --  The first position of Symbol in Text (From .. To), or 0.
   function Index_Of (Text : String; Symbol : Character; From : Positive; To : Natural) return Natural
      with Pre  => From >= Text'First and then To <= Text'Last,
           Post => Index_Of'Result = 0 or else Index_Of'Result in From .. To
   is begin
      for Position in From .. To loop
         if Text (Position) = Symbol then
            return Position;
         end if;
      end loop;
      return 0;
   end Index_Of;

   -------------------
   -- Last_Index_Of --
   -------------------

   --  The last position of Symbol in Text (From .. To), or 0.
   function Last_Index_Of (Text : String; Symbol : Character; From : Positive; To : Natural) return Natural
      with Pre  => From >= Text'First and then To <= Text'Last,
           Post => Last_Index_Of'Result = 0 or else Last_Index_Of'Result in From .. To
   is begin
      for Position in reverse From .. To loop
         if Text (Position) = Symbol then
            return Position;
         end if;
      end loop;
      return 0;
   end Last_Index_Of;

   ---------------
   -- Hex_Value --
   ---------------

   function Hex_Value (Symbol : Character) return Natural is
     (case Symbol is
         when '0' .. '9' => Character'Pos (Symbol) - Character'Pos ('0'),
         when 'a' .. 'f' => Character'Pos (Symbol) - Character'Pos ('a') + 10,
         when 'A' .. 'F' => Character'Pos (Symbol) - Character'Pos ('A') + 10,
         when others => 0)
   with Post => Hex_Value'Result <= 15;

   ---------------------
   -- Percent_Decoded --
   ---------------------

   --  Percent-decoding of URL parts; a '%' without two characters after it stays as it is.
   function Percent_Decoded (Text : String) return String
      with Post => Percent_Decoded'Result'Length <= Text'Length
   is
      Result : String (1 .. Text'Length) := [others => ' '];
      Last   : Natural := 0;
      Next   : Natural := 0;   --  offset in Text
   begin
      while Next < Text'Length loop
         pragma Loop_Invariant (Last <= Next);
         pragma Loop_Variant (Increases => Next);
         Last := Last + 1;
         if Text (Text'First + Next) = '%' and then Text'Length - Next >= 3 then
            Result (Last) := Character'Val (Hex_Value (Text (Text'First + Next + 1)) * 16
                                            + Hex_Value (Text (Text'First + Next + 2)));
            Next := Next + 3;
         else
            Result (Last) := Text (Text'First + Next);
            Next          := Next + 1;
         end if;
      end loop;
      return Result (1 .. Last);
   end Percent_Decoded;

   -------------------
   -- Parse_Address --
   -------------------

   --  "a.b.c.d" or "localhost".
   procedure Parse_Address (Text : String; Address : out Linux.IPv4_Address; Valid : out Boolean) is
      use type Linux.IPv4_Address;
      Octet       : Linux.IPv4_Address := 0;
      Octets_Done : Natural := 0;
      Digit_Count : Natural := 0;
   begin
      Address := 0;
      Valid   := False;
      if Text = "localhost" then
         Address := Linux.Loopback;
         Valid   := True;
         return;
      end if;

      for Symbol of Text loop
         pragma Loop_Invariant (Octet <= 255 and then Digit_Count <= 3 and then Octets_Done <= 3);
         if Symbol in '0' .. '9' then
            Octet       := Octet * 10 + Linux.IPv4_Address (Character'Pos (Symbol) - Character'Pos ('0'));
            Digit_Count := Digit_Count + 1;
            if Octet > 255 or else Digit_Count > 3 then
               return;
            end if;
         elsif Symbol = '.' and then Digit_Count > 0 and then Octets_Done < 3 then
            Address     := Address * 256 or Octet;
            Octets_Done := Octets_Done + 1;
            Octet       := 0;
            Digit_Count := 0;
         else
            return;
         end if;
      end loop;

      if Octets_Done = 3 and then Digit_Count > 0 then
         Address := Address * 256 or Octet;
         Valid   := True;
      end if;
   end Parse_Address;

   -------------------
   -- Decimal_Value --
   -------------------

   --  A decimal of 1 .. 9 digits; -1 when Text is anything else.
   function Decimal_Value (Text : String) return Integer
      with Post => Decimal_Value'Result in -1 .. 999_999_999
   is
      Value : Integer := 0;
   begin
      if Text'Length not in 1 .. 9 then
         return -1;
      end if;

      for Offset in 0 .. Text'Length - 1 loop
         pragma Loop_Invariant (Value in 0 .. 10 ** Offset - 1);
         if Text (Text'First + Offset) not in '0' .. '9' then
            return -1;
         end if;
         Value := Value * 10 + (Character'Pos (Text (Text'First + Offset)) - Character'Pos ('0'));
      end loop;
      return Value;
   end Decimal_Value;

   ------------
   -- Xor_Of --
   ------------

   function Xor_Of (Left, Right : Sha256.Digest) return Sha256.Digest is
     ([for Position in Sha256.Digest'Range =>
         Character'Val (Unsigned_8 (Character'Pos (Left (Position)))
                        xor Unsigned_8 (Character'Pos (Right (Position))))]);

   ---------------
   -- Attribute --
   ---------------

   --  The value of attribute Name ("r", "s", "i") in a SCRAM message "r=...,s=...,i=..."; "" when absent.
   function Attribute (Text : String; Name : Character) return String
      with Pre => Text'Last < Positive'Last, Post => Attribute'Result'Length <= Text'Length
   is
      First : Positive;
   begin
      if Text'Length < 2 then
         return "";
      end if;

      First := Text'First;
      while First < Text'Last loop
         pragma Loop_Invariant (First >= Text'First);
         pragma Loop_Variant (Increases => First);
         declare
            Comma : constant Natural := Index_Of (Text, ',', First, Text'Last);
            Last  : constant Natural := (if Comma = 0 then Text'Last else Comma - 1);
         begin
            if Text (First) = Name and then Text (First + 1) = '=' then
               return Text (First + 2 .. Last);
            end if;
            exit when Comma = 0;
            First := Comma + 1;
         end;
      end loop;
      return "";
   end Attribute;

   Max_Iterations : constant := 10_000_000;

   ------------------------
   -- Authenticate_Scram --
   ------------------------

   --  SCRAM-SHA-256 (RFC 5802, RFC 7677) without channel binding.
   procedure Authenticate_Scram (This : in out Connection; Password : String)
      with Pre               => Valid (This) and then Password'Length <= Max_Message,
           Post              => Valid (This),
           Global            => (In_Out => Socket_IO.Kernel),
           Exceptional_Cases => (Connection_Error => Valid (This))
   is
      Nonce_Bytes : String (1 .. 18);
   begin
      Socket_IO.Random_Bytes (Nonce_Bytes);
      declare
         Client_First_Bare : constant String := "n=,r=" & Base64.Encode (Nonce_Bytes);
         Client_First      : constant String := "n,," & Client_First_Bare;
         Reply             : Message;
      begin
         Begin_Message (This, Password_Message);
         Append_C_String (This, "SCRAM-SHA-256");
         Append_Big_Endian (This.Outgoing, Unsigned_32 (Client_First'Length));
         Append (This.Outgoing, Client_First);
         End_Message (This);
         Write_All (This);

         Next_Message (This, Reply);
         if Reply.Kind = Error_Response then
            Fail (This, "authentication: " & Clip (Error_Field (This, Reply, 'M')));
         elsif Reply.Kind /= Authentication or else First_Word (This, Reply) /= 11
           or else Reply.First + 4 > Reply.Last or else Reply.Last - Reply.First > 65_536
         then
            Fail (This, "expected SASL continue");
         end if;

         declare
            Server_First : constant String := This.Incoming.Data (Reply.First + 4 .. Reply.Last);
            Server_Nonce : constant String := Attribute (Server_First, 'r');
            Salt_Text    : constant String := Attribute (Server_First, 's');
            Iterations   : constant Integer := Decimal_Value (Attribute (Server_First, 'i'));
            Salt         : String (1 .. Base64.Decoded_Length (Salt_Text'Length));
            Salt_Last    : Natural;
            Decoded      : Boolean;
         begin
            if Server_Nonce'Length = 0 or else Iterations not in 1 .. Max_Iterations then
               Fail (This, "bad SCRAM challenge");
            end if;

            Base64.Decode (Salt_Text, Salt, Salt_Last, Decoded);
            if not Decoded then
               Fail (This, "bad SCRAM salt");
            end if;

            declare
               Password_Key : constant Sha256.Hmac_Key := Sha256.To_Hmac_Key (Password);
               Block        : Sha256.Digest :=
                 Sha256.Hmac (Password_Key, Salt (1 .. Salt_Last) & ASCII.NUL & ASCII.NUL & ASCII.NUL & ASCII.SOH);
               Salted       : Sha256.Digest := Block;   --  PBKDF2-HMAC-SHA256, one block
            begin
               for Iteration in 2 .. Iterations loop
                  Block  := Sha256.Hmac (Password_Key, Block);
                  Salted := Xor_Of (Salted, Block);
               end loop;

               declare
                  Client_Key       : constant Sha256.Digest := Sha256.Hmac (Salted, "Client Key");
                  Stored_Key       : constant Sha256.Digest := Sha256.Hash (Client_Key);
                  Final_Bare       : constant String := "c=biws,r=" & Server_Nonce;
                  Auth_Message     : constant String := Client_First_Bare & "," & Server_First & "," & Final_Bare;
                  Client_Signature : constant Sha256.Digest := Sha256.Hmac (Stored_Key, Auth_Message);
               begin
                  Begin_Message (This, Password_Message);
                  Append (This.Outgoing, Final_Bare & ",p=" & Base64.Encode (Xor_Of (Client_Key, Client_Signature)));
                  End_Message (This);
                  Write_All (This);
               end;
            end;
         end;
      end;
   end Authenticate_Scram;

   --  postgres://user:password@host:port/database?options. The parts, as spans of Url; Valid is False when the
   --  port is not a port number.
   type Url_Parts is record
      User_First, Password_First, Host_First, Database_First : Positive := 1;
      User_Last, Password_Last, Host_Last, Database_Last     : Natural := 0;
      Has_User, Has_Database                                 : Boolean := False;
      Port                                                   : Linux.Port_Number := 5432;
      Valid                                                  : Boolean := True;
   end record;

   ------------
   -- Inside --
   ------------

   function Inside (Url : String; First : Positive; Last : Natural) return Boolean is
     (Last < First or else (First >= Url'First and then Last <= Url'Last));

   ---------------
   -- Parse_Url --
   ---------------

   function Parse_Url (Url : String) return Url_Parts
      with Pre  => Url'Last < Positive'Last,
           Post => Inside (Url, Parse_Url'Result.User_First, Parse_Url'Result.User_Last)
                   and then Inside (Url, Parse_Url'Result.Password_First, Parse_Url'Result.Password_Last)
                   and then Inside (Url, Parse_Url'Result.Host_First, Parse_Url'Result.Host_Last)
                   and then Inside (Url, Parse_Url'Result.Database_First, Parse_Url'Result.Database_Last)
   is
      Parts         : Url_Parts;
      Scheme_End    : Natural := 0;
      Rest          : Positive;
      Options       : Natural;
      Last          : Natural;
      Slash         : Natural;
      Authority_End : Natural;
      At_Sign       : Natural;
      Host_First    : Positive;
      Colon         : Natural;
      Port_Colon    : Natural;
   begin
      if Url'Length = 0 then
         Parts.Valid := False;
         return Parts;
      end if;

      if Url'Length >= 3 then
         for Position in Url'First .. Url'Last - 2 loop
            if Url (Position .. Position + 2) = "://" then
               Scheme_End := Position;
               exit;
            end if;
         end loop;
      end if;

      Rest := (if Scheme_End = 0 then Url'First else Scheme_End + 3);
      if Rest > Url'Last then
         Parts.Valid := False;
         return Parts;
      end if;

      Options       := Index_Of (Url, '?', Rest, Url'Last);
      Last          := (if Options = 0 then Url'Last else Options - 1);
      Slash         := Index_Of (Url, '/', Rest, Last);
      Authority_End := (if Slash = 0 then Last else Slash - 1);
      At_Sign       := Last_Index_Of (Url, '@', Rest, Authority_End);
      Host_First    := (if At_Sign = 0 then Rest else At_Sign + 1);
      Colon         := (if At_Sign = 0 then 0 else Index_Of (Url, ':', Rest, At_Sign - 1));
      Port_Colon    := (if Host_First > Authority_End then 0 else Index_Of (Url, ':', Host_First, Authority_End));

      if At_Sign /= 0 then
         Parts.Has_User   := True;
         Parts.User_First := Rest;
         Parts.User_Last  := (if Colon = 0 then At_Sign - 1 else Colon - 1);
         if Colon /= 0 then
            Parts.Password_First := Colon + 1;
            Parts.Password_Last  := At_Sign - 1;
         end if;
      end if;

      Parts.Host_First := Host_First;
      Parts.Host_Last  := (if Port_Colon = 0 then Authority_End else Port_Colon - 1);

      if Slash /= 0 then
         Parts.Has_Database   := True;
         Parts.Database_First := Slash + 1;
         Parts.Database_Last  := Last;
      end if;

      if Port_Colon /= 0 then
         declare
            Port : constant Integer := Decimal_Value (Url (Port_Colon + 1 .. Authority_End));
         begin
            if Port in 0 .. Integer (Linux.Port_Number'Last) then
               Parts.Port := Linux.Port_Number (Port);
            else
               Parts.Valid := False;
            end if;
         end;
      end if;

      return Parts;
      end Parse_Url;

   -------------
   -- Connect --
   -------------

   procedure Connect (This : in out Connection; Url : String) is
      Parts : constant Url_Parts := Parse_Url (Url);
   begin
      if not Parts.Valid or else Url'Length > 65_536 then
         Fail (This, "DATABASE_URL is malformed or has a bad port");
      end if;

      declare
         User     : constant String :=
           (if Parts.Has_User then Percent_Decoded (Url (Parts.User_First .. Parts.User_Last)) else "postgres");
         Password : constant String := Percent_Decoded (Url (Parts.Password_First .. Parts.Password_Last));
         Host     : constant String := Url (Parts.Host_First .. Parts.Host_Last);
         Database : constant String :=
           (if Parts.Has_Database then Percent_Decoded (Url (Parts.Database_First .. Parts.Database_Last))
            else User);
         Address  : Linux.IPv4_Address;
         Resolved : Boolean;
         Reply    : Message;
      begin
         Parse_Address (Host, Address, Resolved);
         if not Resolved then
            Fail (This, "DATABASE_URL host must be an IPv4 address or localhost: " & Clip (Host));
         end if;

         Allocate (This.Outgoing, 65_536);
         Allocate (This.Incoming, 262_144);
         This.Unread             := 1;
         This.Parameters_Missing := 0;
         if This.Fields = null then
            This.Fields      := new Field_Array'(1 .. 65_536 => <>);
            This.Field_Count := 0;
         end if;

         Socket_IO.Connect (Address, Parts.Port, This.Socket);
         if This.Socket = Linux.No_Descriptor then
            Fail (This, "connect to " & Clip (Host) & " failed");
         end if;

         --  StartupMessage: protocol 3.0, plus the session settings every statement here was planned for.
         Append_Big_Endian (This.Outgoing, Unsigned_32'(0));
         Append_Big_Endian (This.Outgoing, Unsigned_32'(196_608));
         Append_C_String (This, "user");
         Append_C_String (This, User);
         Append_C_String (This, "database");
         Append_C_String (This, Database);
         Append_C_String (This, "application_name");
         Append_C_String (This, "conduit-ada");
         Append_C_String (This, "jit");
         Append_C_String (This, "off");
         Append_C_String (This, "max_parallel_workers_per_gather");
         Append_C_String (This, "0");
         Append (This.Outgoing, ASCII.NUL);
         Patch (This.Outgoing, 1, Unsigned_32 (This.Outgoing.Length));
         Write_All (This);

         loop
            pragma Loop_Invariant (Valid (This));
            Next_Message (This, Reply);
            case Reply.Kind is
               when Authentication =>
                  case First_Word (This, Reply) is
                     when 0 | 12 =>
                        null;   --  AuthenticationOk, SASLFinal
                     when 3 =>
                        Begin_Message (This, Password_Message);
                        Append_C_String (This, Password);
                        End_Message (This);
                        Write_All (This);
                     when 10 =>
                        Authenticate_Scram (This, Password);
                     when others =>
                        Fail (This, "unsupported authentication method");
                  end case;
               when Error_Response =>
                  Fail (This, "startup: " & Clip (Error_Field (This, Reply, 'M')));
               when Ready_For_Query =>
                  exit;
               when others =>
                  null;   --  ParameterStatus, BackendKeyData, notices
            end case;
         end loop;

         Compact (This);
         end;
         end Connect;

   ----------------
   -- Disconnect --
   ----------------

   procedure Disconnect (This : in out Connection) is begin
      if This.Socket /= Linux.No_Descriptor then
         Socket_IO.Close (This.Socket);
         This.Socket := Linux.No_Descriptor;
      end if;

      Free (This.Outgoing);
      Free (This.Incoming);
      Free (This.Fields);
      This.Unread             := 1;
      This.Field_Count        := 0;
      This.Parameters_Missing := 0;
   end Disconnect;

   -------------
   -- Prepare --
   -------------

   pragma Warnings (GNATprove, Off, "initialization of ""Reason*"" has no effect", Reason => "read by Fail");
   pragma Warnings (GNATprove, Off, "unused assignment", Reason => "Reason is read by Fail");
   procedure Prepare (This : in out Connection; Query : Statement) is
      Reply         : Message;
      Failed        : Boolean := False;
      Reason        : String (1 .. 200) := [others => ' '];
      Reason_Length : Natural range 0 .. Reason'Length := 0;
   begin
      Begin_Message (This, Parse_Message);
      Append_C_String (This, Query.Name);
      Append_C_String (This, Query.Text);
      Append_Big_Endian (This.Outgoing, Unsigned_16 (Query.Parameter_Count));
      for Parameter_Type of Query.Parameter_Types loop
         pragma Loop_Invariant (Valid (This));
         Append_Big_Endian (This.Outgoing, Unsigned_32 (Parameter_Type));
      end loop;
      End_Message (This);
      Sync (This);
      Write_All (This);

      loop
         pragma Loop_Invariant (Valid (This));
         Next_Message (This, Reply);
         if Reply.Kind = Error_Response and then not Failed then
            declare
               Text : constant String := Clip (Error_Field (This, Reply, 'M'));
            begin
               Failed                      := True;
               Reason_Length               := Text'Length;
               Reason (1 .. Reason_Length) := Text;
            end;
         end if;
         exit when Reply.Kind = Ready_For_Query;
      end loop;

      Compact (This);
      if Failed then
         Fail (This, "prepare " & Clip (Query.Name) & ": " & Reason (1 .. Reason_Length));
      end if;
   end Prepare;
   pragma Warnings (GNATprove, On, "initialization of ""Reason*"" has no effect");
   pragma Warnings (GNATprove, On, "unused assignment");

   ---------------------------------------------------------------------------------------------------------------
   --  pipelines

   ----------
   -- Bind --
   ----------

   procedure Bind (This : in out Connection; Query : Statement) is begin
      if This.Parameters_Missing /= 0 then
         Unsendable (This);   --  the previous statement is missing parameters
      end if;

      Begin_Message (This, Bind_Message);
      Append (This.Outgoing, ASCII.NUL);   --  the unnamed portal
      Append_C_String (This, Query.Name);
      Append_Big_Endian (This.Outgoing, Unsigned_16'(1));   --  one format code for every parameter:
      Append_Big_Endian (This.Outgoing, Binary_Format);
      Append_Big_Endian (This.Outgoing, Unsigned_16 (Query.Parameter_Count));
      This.Parameters_Missing := Query.Parameter_Count;
   end Bind;

   -----------
   -- Added --
   -----------

   --  One parameter more; more than the statement takes makes the pipeline unsendable.
   procedure Added (This : in out Connection)
      with Inline, Pre => Valid (This), Post => Valid (This) and then This.Unread = This.Unread'Old
   is begin
      if This.Parameters_Missing = 0 then
         Unsendable (This);
      else
         This.Parameters_Missing := This.Parameters_Missing - 1;
      end if;
   end Added;

   -------------------
   -- Add_Parameter --
   -------------------

   procedure Add_Parameter (This : in out Connection; Value : String) is begin
      Append_Big_Endian (This.Outgoing, Unsigned_32 (Value'Length));
      Append (This.Outgoing, Value);
      Added (This);
   end Add_Parameter;

   -------------------
   -- Add_Parameter --
   -------------------

   procedure Add_Parameter (This : in out Connection; Value : Long_Long_Integer) is begin
      Append_Big_Endian (This.Outgoing, Unsigned_32'(8));
      Append_Big_Endian (This.Outgoing, Unsigned_64'Mod (Value));
      Added (This);
   end Add_Parameter;

   ------------------
   -- Add_Optional --
   ------------------

   procedure Add_Optional (This : in out Connection; Value : String_Access) is begin
      if Value = null then
         Append_Big_Endian (This.Outgoing, Unsigned_32'(16#FFFF_FFFF#));   --  length -1: NULL
         Added (This);
      else
         Add_Parameter (This, Value.all);
      end if;
   end Add_Optional;

   -----------------
   -- Begin_Array --
   -----------------

   procedure Begin_Array (This : in out Connection; Element_Type : Type_Oid; Count : Natural) is begin
      This.Array_Start := This.Outgoing.Length + 1;
      Append_Big_Endian (This.Outgoing, Unsigned_32'(0));   --  the length, set by End_Array
      if Count = 0 then
         Append_Big_Endian (This.Outgoing, Unsigned_32'(0));   --  an empty array has no dimensions
         Append_Big_Endian (This.Outgoing, Unsigned_32'(0));
         Append_Big_Endian (This.Outgoing, Unsigned_32 (Element_Type));
      else
         Append_Big_Endian (This.Outgoing, Unsigned_32'(1));   --  dimensions
         Append_Big_Endian (This.Outgoing, Unsigned_32'(0));   --  no NULL elements
         Append_Big_Endian (This.Outgoing, Unsigned_32 (Element_Type));
         Append_Big_Endian (This.Outgoing, Unsigned_32 (Count));
         Append_Big_Endian (This.Outgoing, Unsigned_32'(1));   --  lower bound
      end if;
   end Begin_Array;

   -----------------
   -- Add_Element --
   -----------------

   procedure Add_Element (This : in out Connection; Value : String) is begin
      Append_Big_Endian (This.Outgoing, Unsigned_32 (Value'Length));
      Append (This.Outgoing, Value);
   end Add_Element;

   -----------------
   -- Add_Element --
   -----------------

   procedure Add_Element (This : in out Connection; Value : Long_Long_Integer) is begin
      Append_Big_Endian (This.Outgoing, Unsigned_32'(8));
      Append_Big_Endian (This.Outgoing, Unsigned_64'Mod (Value));
   end Add_Element;

   ---------------
   -- End_Array --
   ---------------

   procedure End_Array (This : in out Connection) is begin
      if This.Outgoing.Length >= 3 and then This.Array_Start <= This.Outgoing.Length - 3 then
         Patch (This.Outgoing, This.Array_Start, Unsigned_32 (This.Outgoing.Length - This.Array_Start - 3));
      else
         Unsendable (This);
      end if;

      Added (This);
      end End_Array;

   --------------------
   -- Add_Text_Array --
   --------------------

   procedure Add_Text_Array (This : in out Connection; Items : String_List) is begin
      Begin_Array (This, Text_Oid, Items'Length);
      for Item of Items loop
         pragma Loop_Invariant (Valid (This));
         if Item /= null then
            Add_Element (This, Item.all);
         else
            Add_Element (This, "");
         end if;
      end loop;
      End_Array (This);
   end Add_Text_Array;

   -------------
   -- Execute --
   -------------

   procedure Execute (This : in out Connection) is begin
      if This.Parameters_Missing /= 0 then
         Unsendable (This);
      end if;

      Append_Big_Endian (This.Outgoing, Unsigned_16'(1));   --  one format code for every result column:
      Append_Big_Endian (This.Outgoing, Binary_Format);
      End_Message (This);
      Begin_Message (This, Execute_Message);
      Append (This.Outgoing, ASCII.NUL);                    --  the unnamed portal
      Append_Big_Endian (This.Outgoing, Unsigned_32'(0));   --  all rows
      End_Message (This);
   end Execute;

   ----------
   -- Sync --
   ----------

   procedure Sync (This : in out Connection) is begin
      Append (This.Outgoing, Sync_Message);
      Append_Big_Endian (This.Outgoing, Unsigned_32'(4));
   end Sync;

   -----------
   -- Flush --
   -----------

   procedure Flush (This : in out Connection) is begin
      if This.Outgoing.Length > 0 or else This.Outgoing.Overflowed then
         Write_All (This);
      end if;
   end Flush;

   --------------------
   -- Discard_Unsent --
   --------------------

   procedure Discard_Unsent (This : in out Connection) is begin
      Clear (This.Outgoing);
      This.Parameters_Missing := 0;
   end Discard_Unsent;

   ---------------
   -- Add_Field --
   ---------------

   --  Append Item to the field table, growing it; Added is False when the table is full.
   procedure Add_Field (Fields : in out Field_Array_Access; Count : in out Natural; Item : Field; Added : out Boolean)
      with Inline,
           Pre  => (if Fields = null then Count = 0 else Fields'First = 1 and then Count <= Fields'Last),
           Post => (if Fields = null then Count = 0 else Fields'First = 1 and then Count <= Fields'Last)
   is begin
      Added := False;

      if Fields = null or else Count = Fields'Last then
         if Count >= Max_Fields then
            return;
         end if;
         declare
            Larger : constant Field_Array_Access :=
              new Field_Array'(1 .. (if Fields = null then 65_536 else 2 * Count + 1) => <>);
         begin
            if Fields /= null then
               Larger (1 .. Count) := Fields (1 .. Count);
               Free (Fields);
            end if;
            Fields := Larger;
         end;
      end if;

      Count          := Count + 1;
      Fields (Count) := Item;
      Added          := True;
   end Add_Field;

   --------------
   -- Take_Row --
   --------------

   --  The fields of the DataRow Reply into the field table, as a row of Result; Taken is False when the row is
   --  malformed, has a different column count than the rows before it, or does not fit.
   procedure Take_Row (Data   : String;
                       Reply  : Message;
                       Result : in out Statement_Result;
                       Fields : in out Field_Array_Access;
                       Count  : in out Natural;
                       Taken  : out Boolean)
   with Pre  => Postgres_Wire.Framed (Data)
                and then Reply.Last <= Data'Last
                and then Reply.First < Reply.Last
                and then (if Fields = null
                          then Count = 0
                          else Fields'First = 1 and then Count <= Fields'Last),
        Post => (if Fields = null then Count = 0 else Fields'First = 1 and then Count <= Fields'Last)
   is
      Columns  : constant Natural := Postgres_Wire.Short (Data, Reply.First);
      Position : Positive := Reply.First + 2;
      Item     : Postgres_Wire.Field;
      Framed   : Boolean;
   begin
      Taken := False;

      if Result.Row_Count = 0 then
         if Count = Natural'Last then
            return;
         end if;
         Result.First_Field  := Count + 1;
         Result.Column_Count := Columns;
      elsif Columns /= Result.Column_Count or else Result.Row_Count = Natural'Last then
         return;
      end if;

      Result.Row_Count := Result.Row_Count + 1;
      for Column in 1 .. Columns loop
         pragma Loop_Invariant (if Fields = null then Count = 0 else Fields'First = 1 and then Count <= Fields'Last);
         Postgres_Wire.Next_Column (Data, Reply.Last, Position, Item, Framed);
         if not Framed then
            return;
         end if;
         Add_Field (Fields, Count, Field (Item), Framed);
         if not Framed then
            return;
         end if;
      end loop;

      Taken := True;
      end Take_Row;

   ------------------
   -- Read_Results --
   ------------------

   procedure Read_Results (This : in out Connection; Results : out Result_Array; Keep_Earlier : Boolean := False) is
      Done  : Natural := 0;   --  Executes whose replies are complete; the next one's are arriving
      Reply : Message;
      Taken : Boolean;
   begin
      Results := [others => <>];
      if not Keep_Earlier then
         Compact (This);
         This.Field_Count := 0;
      end if;

      loop
         pragma Loop_Invariant (Valid (This) and then Done <= Results'Length);
         Next_Message (This, Reply);
         case Reply.Kind is
            when Data_Row =>
               if Done < Results'Length then
                  if Reply.Last < Reply.First + 1 or else This.Incoming.Data = null then
                     Fail (This, "malformed DataRow");
                  end if;
                  Take_Row (Data   => This.Incoming.Data (1 .. This.Incoming.Length),
                            Reply  => Reply,
                            Result => Results (Results'First + Done),
                            Fields => This.Fields,
                            Count  => This.Field_Count,
                            Taken  => Taken);
                  if not Taken then
                     Fail (This, "malformed DataRow");
                  end if;
               end if;
            when Command_Complete | Empty_Query =>
               if Done < Results'Length then
                  Results (Results'First + Done).Succeeded := True;
                  Done := Done + 1;
               end if;
            when Error_Response =>
               if Done < Results'Length then
                  declare
                     State : constant String := Error_Field (This, Reply, 'C');
                  begin
                     if State'Length = Sql_State'Length then
                        Results (Results'First + Done).State := State;
                     end if;
                  end;
               end if;
               Done := Results'Length;   --  Postgres skips the rest of the group
            when Ready_For_Query =>
               exit;
            when others =>
               null;   --  BindComplete, NoData, notices, ParameterStatus
         end case;
      end loop;
   end Read_Results;

   ---------------
   -- Try_Flush --
   ---------------

   procedure Try_Flush (This : in out Connection; Sent : out Boolean) is begin
      Flush (This);
      Sent := True;
   exception
      when Connection_Error =>
         Sent := False;
   end Try_Flush;

   ----------------------
   -- Try_Read_Results --
   ----------------------

   procedure Try_Read_Results
     (This : in out Connection; Results : out Result_Array; Received : out Boolean; Keep_Earlier : Boolean := False)
   is
      Got : Result_Array (Results'Range);
   begin
      Read_Results (This, Got, Keep_Earlier);
      Results  := Got;
      Received := True;
   exception
      when Connection_Error =>
         Results  := [others => <>];
         Received := False;
   end Try_Read_Results;

   ------------------
   -- Last_Failure --
   ------------------

   function Last_Failure (This : Connection) return String is (This.Reason (1 .. This.Reason_Length));

   ---------------------------------------------------------------------------------------------------------------
   --  values

   --------------
   -- Field_At --
   --------------

   function Field_At (This : Connection; Result : Statement_Result; Row, Column : Positive) return Field is
      Index : constant Long_Long_Integer := Long_Long_Integer (Result.First_Field)  + Long_Long_Integer (Row - 1) 
                                          * Long_Long_Integer (Result.Column_Count) + Long_Long_Integer (Column - 1);
   begin
      if This.Fields = null or else Row > Result.Row_Count or else Column > Result.Column_Count
        or else Index > Long_Long_Integer (This.Field_Count)
      then
         return Field (Postgres_Wire.Null_Field);   --  outside the result: reads as NULL
      end if;
      return This.Fields (Positive (Index));
   end Field_At;

   ----------
   -- Text --
   ----------

   function Text (This : Connection; Item : Field) return String is
     (if This.Incoming.Data = null then ""
      else Postgres_Wire.Text (This.Incoming.Data (1 .. This.Incoming.Length), Wire (Item)));

   -------------------
   -- Integer_Value --
   -------------------

   function Integer_Value (This : Connection; Item : Field) return Long_Long_Integer is
     (if This.Incoming.Data = null then 0
      else Postgres_Wire.Integer_Value (This.Incoming.Data (1 .. This.Incoming.Length), Wire (Item)));

   -------------------
   -- Boolean_Value --
   -------------------

   function Boolean_Value (This : Connection; Item : Field) return Boolean is
     (if This.Incoming.Data = null then False
      else Postgres_Wire.Boolean_Value (This.Incoming.Data (1 .. This.Incoming.Length), Wire (Item)));

   ---------------------
   -- Timestamp_Value --
   ---------------------

   function Timestamp_Value (This : Connection; Item : Field) return Postgres_Timestamp is
     (Postgres_Timestamp (Integer_Value (This, Item)));

   -------------------
   -- Element_Count --
   -------------------

   function Element_Count (This : Connection; Item : Field) return Natural is
     (if This.Incoming.Data = null then 0
      else Postgres_Wire.Element_Count (This.Incoming.Data (1 .. This.Incoming.Length), Wire (Item)));

   -------------
   -- Element --
   -------------

   function Element (This : Connection; Item : Field; Index : Positive) return Field is
     (if This.Incoming.Data = null then Field (Postgres_Wire.Null_Field)
      else Field (Postgres_Wire.Element (This.Incoming.Data (1 .. This.Incoming.Length), Wire (Item), Index)));

end Postgres;
