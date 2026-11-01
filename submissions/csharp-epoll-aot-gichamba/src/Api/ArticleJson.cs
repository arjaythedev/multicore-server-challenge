using Conduit.Json;
using Conduit.Pg;

namespace Conduit.Api;

/// <summary>Writes the Article and Profile objects of SPEC.md from result rows, and reads the int4[] of tag ids.</summary>
internal static class ArticleJson {
    /// <summary>
    /// Writes one Article object from the row columns starting at <paramref name="first"/>: id, slug, title, description,
    /// [body], created_at, updated_at, then the columns of <see cref="ArticleSql.Tail"/>: tag_list, favorites_count,
    /// favorited, username, bio, image, following. The id is read past, not written.
    /// </summary>
    public static void WriteArticle(JsonWriter w, in PgRow row, int first, bool withBody) {
        int c = first + 1;
        int slugAt = c++, titleAt = c++, descriptionAt = c++;
        int bodyAt = withBody ? c++ : -1;
        int createdAt = c++, updatedAt = c++;
        int tagsAt = c++, favoritesAt = c++, favoritedAt = c++, userAt = c;

        w.StartObject();
        w.PropertyName("slug"u8);
        w.WriteString(row[slugAt]);
        w.PropertyName("title"u8);
        w.WriteString(row[titleAt]);
        w.PropertyName("description"u8);
        w.WriteString(row[descriptionAt]);
        if (withBody) {
            w.PropertyName("body"u8);
            w.WriteString(row[bodyAt]);
        }
        w.PropertyName("createdAt"u8);
        w.WriteTimestamp(PgBinary.ReadTimestamptz(row[createdAt]));
        w.PropertyName("updatedAt"u8);
        w.WriteTimestamp(PgBinary.ReadTimestamptz(row[updatedAt]));
        w.PropertyName("tagList"u8);
        w.StartArray();
        foreach (string? tag in PgBinary.ReadTextArray(row[tagsAt])) {
            w.WriteString(tag ?? "");
        }
        w.EndArray();
        w.PropertyName("favorited"u8);
        w.WriteBool(PgBinary.ReadBool(row[favoritedAt]));
        w.PropertyName("favoritesCount"u8);
        w.WriteLong(PgBinary.ReadInt8(row[favoritesAt]));
        w.PropertyName("author"u8);
        WriteProfile(w, row, userAt, userAt + 3);
        w.EndObject();
    }

    /// <summary>Writes a Profile from username, bio, image at <paramref name="at"/> and a following bool at <paramref name="followingAt"/>.</summary>
    public static void WriteProfile(JsonWriter w, in PgRow row, int at, int followingAt) {
        w.StartObject();
        w.PropertyName("username"u8);
        w.WriteString(row[at]);
        w.PropertyName("bio"u8);
        UserFamily.Nullable(w, row, at + 1);
        w.PropertyName("image"u8);
        UserFamily.Nullable(w, row, at + 2);
        w.PropertyName("following"u8);
        w.WriteBool(PgBinary.ReadBool(row[followingAt]));
        w.EndObject();
    }

    /// <summary>Reads a one-dimensional int4[] in binary format; NULL or no dimensions gives an empty array.</summary>
    public static int[] ReadInt4Array(ReadOnlySpan<byte> array) {
        // 20 bytes of header: dims, has-nulls flag, element oid, then length and lower bound. Fewer means no elements.
        if (array.Length < 20) {
            return [];
        }

        int[] ids = new int[PgBinary.ReadInt4(array[12..])];
        for (int i = 0, at = 20; i < ids.Length; i++, at += 8) {  // each element: 4-byte length, 4-byte value
            ids[i] = PgBinary.ReadInt4(array[(at + 4)..]);
        }

        return ids;
    }
}
