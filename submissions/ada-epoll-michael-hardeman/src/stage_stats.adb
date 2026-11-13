with Formatting; use Formatting;

package body Stage_Stats with SPARK_Mode is

   Interval : constant := 10_000;   --  milliseconds between reports

   ---------
   -- Sum --
   ---------

   function Sum (Left : Total; Right : Long_Long_Integer) return Total is
     (if Right <= 0 then Left elsif Right >= Limit - Left then Limit else Left + Right);

   -----------
   -- Start --
   -----------

   procedure Start (This : out Counters; Now : Milliseconds) is begin
      This := (Since => Now, others => 0);
   end Start;

   ---------
   -- Add --
   ---------

   procedure Add (This : in out Counters; Jobs : Natural; Queued, Taken, Done : Milliseconds) is
      Wait : constant Long_Long_Integer :=
        (if Queued in 0 .. Limit and then Taken in Queued .. Limit then Long_Long_Integer (Taken - Queued) else 0);
      Work : constant Long_Long_Integer :=
        (if Taken in 0 .. Limit and then Done in Taken .. Limit then Long_Long_Integer (Done - Taken) else 0);
   begin
      This.Batches  := Sum (This.Batches, 1);
      This.Jobs     := Sum (This.Jobs, Long_Long_Integer (Jobs));
      This.Wait     := Sum (This.Wait, Wait);
      This.Max_Wait := Total'Max (This.Max_Wait, Wait);
      This.Work     := Sum (This.Work, Work);
   end Add;

   ------------
   -- Report --
   ------------

   procedure Report (This : in out Counters; Name : String; Now : Milliseconds) is
      Elapsed : constant Long_Long_Integer :=
        (if This.Since in 0 .. Limit and then Now >= This.Since then Long_Long_Integer (Now - This.Since) else 0);
      Batches : constant Total := Total'Max (This.Batches, 1);
   begin
      if Elapsed < Interval then
         return;
      end if;

      if Settings.Stats then
         Effects.Log
           ("stats " & Name
            & ": batches " & Decimal_Image (This.Batches)
            & ", jobs/batch " & Decimal_Image (This.Jobs / Batches)
            & ", wait avg " & Decimal_Image (This.Wait / Batches)
            & " max " & Decimal_Image (This.Max_Wait)
            & " ms, work avg " & Decimal_Image (This.Work / Batches)
            & " ms, busy " & Decimal_Image (This.Work / (Elapsed / 100)) & "%");
      end if;

      Start (This, Now);
   end Report;

end Stage_Stats;
