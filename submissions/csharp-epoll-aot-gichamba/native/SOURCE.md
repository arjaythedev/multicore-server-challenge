# Native bcrypt source

`crypt_blowfish.c` and `crypt_blowfish.h` are Openwall crypt_blowfish 1.3, copied unchanged.

- Source: https://www.openwall.com/crypt/crypt_blowfish-1.3.tar.gz
- Tarball SHA-256: `83fa01fca6996fe8d882b7f8e9ba0305a5664936100b01481ea3c6a8ce8d72fd`
- `crypt_blowfish.c` SHA-256: `d850f7aadcebfe6dc211652a459feb90aa3739409972d3a7dfa8c9349b648ec6`
- `crypt_blowfish.h` SHA-256: `1307f3579b0e884c57aa7098be2a49304154db4b63e0a758adb1c3f3e38b600f`

`bcrypt_lanes.c` is ours. It includes `crypt_blowfish.c` and adds `conduit_bcrypt_lanes`
(interleaved bcrypt for 1 to 8 passwords) and `conduit_bcrypt_gensalt`.
`build-native.sh` builds `libconduit_bcrypt.so` from it.

## Licence

From the header of `crypt_blowfish.c` (Written by Solar Designer <solar at openwall.com> in 1998-2014):

> No copyright is claimed, and the software is hereby placed in the public
> domain.  In case this attempt to disclaim copyright and place the software
> in the public domain is deemed null and void, then the software is
> Copyright (c) 1998-2014 Solar Designer and it is hereby released to the
> general public under the following terms:
>
> Redistribution and use in source and binary forms, with or without
> modification, are permitted.
>
> There's ABSOLUTELY NO WARRANTY, express or implied.
