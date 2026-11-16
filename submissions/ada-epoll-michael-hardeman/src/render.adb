package body Render with SPARK_Mode is

   -----------------
   -- Append_Text --
   -----------------

   procedure Append_Text (Into : in out Buffer; From : Connection; Item : Field)
      with Inline, Pre => Valid (Into), Post => Valid (Into)
   is begin
      Append_Json_String (Into, Text (From, Item));
   end Append_Text;

   -------------------------
   -- Append_Text_Or_Null --
   -------------------------

   procedure Append_Text_Or_Null (Into : in out Buffer; From : Connection; Item : Field)
      with Pre => Valid (Into), Post => Valid (Into)
   is begin
      if Is_Null (Item) then
         Append (Into, "null");
      else
         Append_Text (Into, From, Item);
      end if;
   end Append_Text_Or_Null;

   --------------------
   -- Append_Boolean --
   --------------------

   procedure Append_Boolean (Into : in out Buffer; Value : Boolean)
      with Pre => Valid (Into), Post => Valid (Into)
   is begin
      Append (Into, (if Value then "true" else "false"));
   end Append_Boolean;

   -------------------
   -- Append_Author --
   -------------------

   --  "author": {"username", "bio", "image", "following"}, with the three texts at columns First .. First + 2.
   procedure Append_Author
     (Into : in out Buffer; From : Connection; Rows : Statement_Result; Row, First : Positive; Following : Boolean)
      with Pre => Valid (Into) and then First <= Positive'Last - 2, Post => Valid (Into)
   is begin
      Append (Into, """author"":{""username"":");
      Append_Text (Into, From, Field_At (From, Rows, Row, First));
      Append (Into, ",""bio"":");
      Append_Text_Or_Null (Into, From, Field_At (From, Rows, Row, First + 1));
      Append (Into, ",""image"":");
      Append_Text_Or_Null (Into, From, Field_At (From, Rows, Row, First + 2));
      Append (Into, ",""following"":");
      Append_Boolean (Into, Following);
      Append (Into, "}");
   end Append_Author;

   ----------
   -- User --
   ----------

   procedure User (Into  : in out Buffer;
                   From  : Connection;
                   Rows  : Statement_Result;
                   Token : String;
                   Row   : Positive := 1;
                   First : Positive := 1)
   is
      function Column (Offset : Natural) return Field is (Field_At (From, Rows, Row, First + Offset))
         with Pre => Offset <= 4 and then First <= Positive'Last - 4;
   begin
      Append (Into, "{""user"":{""email"":");
      Append_Text (Into, From, Column (2));
      Append (Into, ",""token"":");
      Append_Json_String (Into, Token);
      Append (Into, ",""username"":");
      Append_Text (Into, From, Column (1));
      Append (Into, ",""bio"":");
      Append_Text_Or_Null (Into, From, Column (3));
      Append (Into, ",""image"":");
      Append_Text_Or_Null (Into, From, Column (4));
      Append (Into, "}}");
   end User;

   -------------
   -- Profile --
   -------------

   procedure Profile (Into      : in out Buffer;
                      From      : Connection;
                      Rows      : Statement_Result;
                      First     : Positive;
                      Following : Boolean;
                      Row       : Positive := 1)
   is begin
      Append (Into, "{""profile"":{""username"":");
      Append_Text (Into, From, Field_At (From, Rows, Row, First));
      Append (Into, ",""bio"":");
      Append_Text_Or_Null (Into, From, Field_At (From, Rows, Row, First + 1));
      Append (Into, ",""image"":");
      Append_Text_Or_Null (Into, From, Field_At (From, Rows, Row, First + 2));
      Append (Into, ",""following"":");
      Append_Boolean (Into, Following);
      Append (Into, "}}");
   end Profile;

   -------------
   -- Comment --
   -------------

   procedure Comment (Into      : in out Buffer;
                      From      : Connection;
                      Rows      : Statement_Result;
                      Row       : Positive;
                      Following : Boolean)
   is begin
      Append (Into, "{""id"":");
      Append_Integer (Into, Integer_Value (From, Field_At (From, Rows, Row, 1)));
      Append (Into, ",""createdAt"":");
      Append_Timestamp (Into, Timestamp_Value (From, Field_At (From, Rows, Row, 3)));
      Append (Into, ",""updatedAt"":");
      Append_Timestamp (Into, Timestamp_Value (From, Field_At (From, Rows, Row, 4)));
      Append (Into, ",""body"":");
      Append_Text (Into, From, Field_At (From, Rows, Row, 2));
      Append (Into, ',');
      Append_Author (Into, From, Rows, Row, 5, Following);
      Append (Into, "}");
   end Comment;

end Render;
