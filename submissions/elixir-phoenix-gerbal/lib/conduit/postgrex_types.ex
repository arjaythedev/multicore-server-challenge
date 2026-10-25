# Postgrex's default types, decoding binaries by reference: see the Repo's `types:` in config/config.exs.
Postgrex.Types.define(Conduit.PostgrexTypes, [], decode_binary: :reference)
