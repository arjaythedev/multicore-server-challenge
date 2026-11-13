--  Base64 (RFC 4648): the standard alphabet with padding (SCRAM) and the URL alphabet without padding (JWT).
package Base64 with SPARK_Mode is

   type Alphabet is (Standard, Url_Safe);

   --  Standard output is padded with '=' to a multiple of four; Url_Safe output is not padded.
   function Encode (Data : String; Using : Alphabet := Standard) return String
      with Pre  => Data'Length <= 2 ** 30,
           Post => Encode'Result'First = 1 and then Encode'Result'Length <= (Data'Length + 2) / 3 * 4;

   --  The most bytes Decode can produce from Text_Length characters.
   function Decoded_Length (Text_Length : Natural) return Natural is ((Text_Length + 3) / 4 * 3)
      with Pre => Text_Length <= Natural'Last - 3;

   --  Data (Data'First .. Last) receives the bytes. Valid is False on a character outside the alphabet,
   --  an impossible length, or when Data is too short.
   procedure Decode (Text  : String;
                     Data  : out String;
                     Last  : out Natural;
                     Valid : out Boolean;
                     Using : Alphabet := Standard)
      with Pre  => Data'First >= 1,
           Post => Last = Data'First - 1 or else Last in Data'Range;

end Base64;
