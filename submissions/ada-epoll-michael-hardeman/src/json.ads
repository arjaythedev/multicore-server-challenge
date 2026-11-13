--  A small JSON reader for request bodies and JWT segments. A document is a flat table of nodes linked to
--  their first child and next sibling. Strings are decoded (escapes resolved) into the document's own text
--  area. Text Postgres cannot store (invalid UTF-8, NUL) is rejected while parsing, so any string read from a
--  parsed document can be sent to Postgres as is.
--
--  Proved free of run-time errors (SPARK silver): no input makes the parser or the accessors raise, read
--  outside the source or the document, or loop forever.
package Json with SPARK_Mode is

   type Kind is (Null_Kind, True_Kind, False_Kind, Number_Kind, String_Kind, Array_Kind, Object_Kind);

   type Node_Count is range 0 .. 2 ** 20;
   subtype Node_Index is Node_Count range 1 .. Node_Count'Last;
   No_Node : constant Node_Count := 0;
   Root    : constant Node_Index := 1;

   type Document (Node_Capacity : Node_Index; Text_Capacity : Positive) is limited private;

   --  Parse Source into This; on success the top-level value is node Root.
   procedure Parse (This : in out Document; Source : String; Valid : out Boolean)
      with Pre => Source'First >= 1
                  and then Source'Last < Positive'Last
                  and then This.Text_Capacity < Positive'Last;

   --  The member Name of an object node; No_Node when absent or when Object is not an object.
   function Member (This : Document; Object : Node_Count; Name : String) return Node_Count;

   --  An absent node reads as JSON null.
   function Kind_Of (This : Document; Item : Node_Count) return Kind;

   --  A string's decoded text or a number's text; "" for other kinds.
   function Value (This : Document; Item : Node_Count) return String;

   function First_Child (This : Document; Item : Node_Count) return Node_Count
      with Post => First_Child'Result = No_Node or else First_Child'Result > Item;
   function Next_Sibling (This : Document; Item : Node_Count) return Node_Count
      with Post => Next_Sibling'Result = No_Node or else Next_Sibling'Result > Item;

   --  Valid UTF-8 with no NUL: what a Postgres text value can hold.
   function Valid_Text (Text : String) return Boolean;

private

   --  A range of the document's text; First > Last when empty.
   type Span is record
      First : Positive := 1;
      Last  : Natural := 0;
   end record;

   type Node is record
      Of_Kind      : Kind := Null_Kind;
      Key          : Span; --  member name, for the children of an object
      Value        : Span; --  decoded string, or the number's text
      First_Child  : Node_Count := No_Node;
      Next_Sibling : Node_Count := No_Node;
   end record;

   type Node_Array is array (Node_Index range <>) of Node;

   type Document (Node_Capacity : Node_Index; Text_Capacity : Positive) is limited record
      Nodes       : Node_Array (1 .. Node_Capacity);
      Node_Total  : Node_Count := 0;
      Text        : String (1 .. Text_Capacity) := [others => ' '];
      Text_Length : Natural := 0;
   end record;

end Json;
