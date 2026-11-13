--  The API's identifiers and paging, shared by routing, tokens and the database lanes.
package Model with Pure, SPARK_Mode is

   --  Postgres bigserial keys.
   type Row_Key is range 0 .. 2 ** 63 - 1;

   type User_Id is new Row_Key;
   Anonymous : constant User_Id := 0;
   subtype Known_User is User_Id range 1 .. User_Id'Last;

   type Article_Id is new Row_Key;
   type Comment_Id is new Row_Key;

   --  Wall-clock time: seconds since 1970-01-01 UTC (JWT iat / exp).
   type Unix_Seconds is new Long_Long_Integer;

   --  ?limit= and ?offset= of the list endpoints.
   type Page_Limit is range 1 .. 100;
   type Page_Offset is range 0 .. 10 ** 18 - 1;

   type Page_Window is record
      Limit  : Page_Limit := 20;
      Offset : Page_Offset := 0;
   end record;

end Model;
