using System.Text.Json;

namespace Conduit.Api;

/// <summary>What a field of a request body holds.</summary>
internal enum JsonKind : byte {
    /// <summary>The name does not appear.</summary>
    Absent,

    /// <summary>JSON null.</summary>
    Null,

    /// <summary>A string; see <see cref="JsonField.Text"/>.</summary>
    Text,

    /// <summary>An array of non-empty strings; see <see cref="JsonField.Items"/>.</summary>
    Array,

    /// <summary>Anything else: a number, a bool, an object, an array with a bad item, or a string with a NUL character.</summary>
    Other,
}

/// <summary>One field read from a request body.</summary>
internal struct JsonField {
    /// <summary>What the field holds.</summary>
    public JsonKind Kind;

    /// <summary>The string, when <see cref="Kind"/> is Text.</summary>
    public string? Text;

    /// <summary>The strings, when <see cref="Kind"/> is Array.</summary>
    public string[]? Items;

    /// <summary>True for a string with at least one character.</summary>
    public readonly bool IsFilledText => Kind == JsonKind.Text && Text!.Length > 0;
}

/// <summary>Reads the wrapped request bodies of SPEC.md, such as {"user": {...}}, without building a document.</summary>
internal static class JsonBody {
    /// <summary>
    /// Reads <c>{"&lt;wrapper&gt;": {...}}</c> and fills <paramref name="fields"/>[i] with the member called
    /// <paramref name="names"/>[i] of the wrapped object. Other members are ignored. Returns false when the body is not
    /// valid JSON, is not an object, has no wrapper object, has a wrapper that is not an object, or has text after the root.
    /// </summary>
    public static bool TryRead(ReadOnlySpan<byte> body, string wrapper, string[] names, JsonField[] fields) {
        Array.Clear(fields);
        try {
            Utf8JsonReader r = new(body);
            if (!r.Read() || r.TokenType != JsonTokenType.StartObject) {
                return false;
            }

            bool found = false;
            while (r.Read() && r.TokenType == JsonTokenType.PropertyName) {
                bool isWrapper = r.ValueTextEquals(wrapper);
                r.Read();
                if (!isWrapper) {
                    r.Skip();
                    continue;
                }
                if (r.TokenType != JsonTokenType.StartObject) {
                    // A wrapper that is not an object cannot be repaired by a later duplicate: reject.
                    return false;
                }
                ReadFields(ref r, names, fields);
                found = true;
            }
            // The loop ends on the root's closing brace; reading on makes the reader reject trailing text.
            return found && r.TokenType == JsonTokenType.EndObject && !r.Read();
        } catch (Exception ex) when (ex is JsonException or InvalidOperationException or ArgumentException) {
            return false;
        }
    }

    /// <summary>Reads the members of the wrapped object into <paramref name="fields"/>. The reader starts on the object's StartObject and ends on its EndObject.</summary>
    private static void ReadFields(ref Utf8JsonReader r, string[] names, JsonField[] fields) {
        while (r.Read() && r.TokenType == JsonTokenType.PropertyName) {
            int at = -1;
            for (int i = 0; i < names.Length; i++) {
                if (r.ValueTextEquals(names[i])) {
                    at = i;
                    break;
                }
            }
            r.Read();
            if (at < 0) {
                r.Skip();
                continue;
            }
            fields[at] = ReadValue(ref r);
        }
    }

    /// <summary>
    /// Reads the value under the reader. A string or null is kept, and an array of non-empty strings becomes Array. Anything
    /// else is Other: a string with a NUL, an array with an empty, non-string or NUL item, and every other kind of value.
    /// </summary>
    private static JsonField ReadValue(ref Utf8JsonReader r) {
        switch (r.TokenType) {
            case JsonTokenType.String: {
                    string text = r.GetString()!;
                    return text.Contains('\0') ? new JsonField { Kind = JsonKind.Other } : new JsonField { Kind = JsonKind.Text, Text = text };
                }
            case JsonTokenType.Null:
                return new JsonField { Kind = JsonKind.Null };
            case JsonTokenType.StartArray: {
                    List<string> items = [];
                    bool bad = false;
                    while (r.Read() && r.TokenType != JsonTokenType.EndArray) {
                        if (r.TokenType == JsonTokenType.String) {
                            string item = r.GetString()!;
                            if (item.Length == 0 || item.Contains('\0')) {
                                bad = true;
                            } else {
                                items.Add(item);
                            }
                        } else {
                            bad = true;
                            r.Skip();
                        }
                    }
                    return bad ? new JsonField { Kind = JsonKind.Other } : new JsonField { Kind = JsonKind.Array, Items = [.. items] };
                }
            default:
                r.Skip();
                return new JsonField { Kind = JsonKind.Other };
        }
    }
}
