with Ada.Unchecked_Deallocation;

package body Jobs with SPARK_Mode is

   procedure Deallocate is new Ada.Unchecked_Deallocation (Job, Job_Access);

   ----------------------
   -- Strings_Released --
   ----------------------

   --  Every string a job owns, released.
   function Strings_Released (This : Job) return Boolean is
     (case This.Kind is
         when List_Tags        => True,
         when Listing_Endpoint => This.Filter.Kind = No_Filter or else This.Filter.Value = null,
         when Account_Endpoint => This.Account.Username = null
                                  and then This.Account.Email = null
                                  and then This.Account.Password = null
                                  and then This.Account.Bio = null
                                  and then This.Account.Image = null
                                  and then This.Account.Password_Hash = null
                                  and then This.Account.Token = null,
         when Profile_Endpoint => This.Username = null,
         when Article_Endpoint => This.Slug = null
                                  and then This.Article.Title = null
                                  and then This.Article.Description = null
                                  and then This.Article.Text = null
                                  and then This.Article.Tags = null
                                  and then This.Comment_Body = null);

   ---------------------
   -- Release_Strings --
   ---------------------

   procedure Release_Strings (This : in out Job)
      with Pre  => This.Next = null,
           Post => Strings_Released (This) and then This.Next = null
   is begin
      case This.Kind is
         when List_Tags => null;
         when Listing_Endpoint =>
            if This.Filter.Kind /= No_Filter then
               Free (This.Filter.Value);
            end if;
         when Account_Endpoint => Free (This.Account.Username);
                                  Free (This.Account.Email);
                                  Free (This.Account.Password);
                                  Free (This.Account.Bio);
                                  Free (This.Account.Image);
                                  Free (This.Account.Password_Hash);
                                  Free (This.Account.Token);
         when Profile_Endpoint => Free (This.Username);
         when Article_Endpoint => Free (This.Slug);
                                  Free (This.Article.Title);
                                  Free (This.Article.Description);
                                  Free (This.Article.Text);
                                  Free (This.Article.Tags);
                                  Free (This.Comment_Body);
      end case;
   end Release_Strings;

   ----------
   -- Free --
   ----------

   procedure Free (This : in out Job_Access) is begin
      if This = null then
         return;
      end if;
      Release_Strings (This.all);
      Free (This.Response);
      Deallocate (This);
   end Free;

   ----------
   -- Fail --
   ----------

   procedure Fail (This : in out Job; Status : Http.Status_Code) is begin
      This.Status := Status;
      Restart (This.Response);
      Append (This.Response, Http.Error_Body (Status));
   end Fail;

end Jobs;
