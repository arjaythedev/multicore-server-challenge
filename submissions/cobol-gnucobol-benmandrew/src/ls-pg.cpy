*> LINKAGE items private to the pg module.
*> the write buffer of a Postgres connection (PG-WB-PTR)
01 L-PG-WB           PIC X(16777216).
*> the request being built by PB-* (PG-PB-PTR)
01 L-PB              PIC X(16777216).
*> a group member's saved Bind/Execute bytes, for a resend after an error in its group
01 L-PG-RS           PIC X(16777216).
