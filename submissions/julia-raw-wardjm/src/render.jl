# Response JSON, written straight from the binary columns of the current DataRow.

const APP_SORTS_TAGS = Ref(false)
const PG_EPOCH_DAYS = 10957 # 2000-01-01 - 1970-01-01

@inline wcol!(b::Buf, c::PgConn, k::Int) = @inbounds wr_jstr!(b, c.rbuf, c.coff[k], c.clen[k])
@inline wcol_or_null!(b::Buf, c::PgConn, k::Int) = @inbounds wr_jstr_or_null!(b, c.rbuf, c.coff[k], c.clen[k])
@inline wbool!(b::Buf, x::Bool) = wr!(b, x ? "true" : "false")

@inline function wr2!(b::Buf, x::Int)
    wr!(b, UInt8('0') + UInt8(x ÷ 10))
    wr!(b, UInt8('0') + UInt8(x % 10))
end

# timestamptz (µs since 2000-01-01 UTC) as "YYYY-MM-DDTHH:MM:SS.mmmZ", truncated to ms
function wr_ts!(b::Buf, us::Int64)
    ms = fld(us, 1000)
    secs = fld(ms, 1000)
    msr = Int(ms - secs * 1000)
    days = fld(secs, 86400)
    sod = Int(secs - days * 86400)
    # civil_from_days (H. Hinnant), days since 1970-01-01
    z = days + PG_EPOCH_DAYS + 719468
    era = fld(z, 146097)
    doe = z - era * 146097
    yoe = (doe - doe ÷ 1460 + doe ÷ 36524 - doe ÷ 146096) ÷ 365
    y = yoe + era * 400
    doy = doe - (365 * yoe + yoe ÷ 4 - yoe ÷ 100)
    mp = (5 * doy + 2) ÷ 153
    d = Int(doy - (153 * mp + 2) ÷ 5 + 1)
    m = Int(mp < 10 ? mp + 3 : mp - 9)
    y += m <= 2
    reserve!(b, 26)
    wr!(b, UInt8('"'))
    yy = Int(y)
    wr2!(b, yy ÷ 100)
    wr2!(b, yy % 100)
    wr!(b, UInt8('-'))
    wr2!(b, m)
    wr!(b, UInt8('-'))
    wr2!(b, d)
    wr!(b, UInt8('T'))
    wr2!(b, sod ÷ 3600)
    wr!(b, UInt8(':'))
    wr2!(b, (sod ÷ 60) % 60)
    wr!(b, UInt8(':'))
    wr2!(b, sod % 60)
    wr!(b, UInt8('.'))
    wr!(b, UInt8('0') + UInt8(msr ÷ 100))
    wr2!(b, msr % 100)
    wr!(b, "Z\"")
end

@inline wts_col!(b::Buf, c::PgConn, k::Int) = wr_ts!(b, col_i64(c, k))

# a text[] column as a JSON array (sorted by bytes when the database collation is code point order)
function wr_tags!(lp::Loop, b::Buf, c::PgConn, k::Int)
    off = c.coff[k]
    len = c.clen[k]
    v = c.rbuf
    wr!(b, UInt8('['))
    if len >= 12 && load_be(Int32, v, off) > 0
        n = Int(load_be(Int32, v, off + 12))
        p = off + 20
        if APP_SORTS_TAGS[] && n > 1
            to, tl = lp.tagoff, lp.taglen
            if n > length(to)
                resize!(to, n)
                resize!(tl, n)
            end
            for j in 1:n
                l = Int(load_be(Int32, v, p))
                p += 4
                # insertion sort as we go
                q = j
                while q > 1 && bytes_cmp(v, to[q-1], tl[q-1], v, p, l) > 0
                    to[q] = to[q-1]
                    tl[q] = tl[q-1]
                    q -= 1
                end
                to[q] = p
                tl[q] = l
                p += max(l, 0)
            end
            for j in 1:n
                j > 1 && wr!(b, UInt8(','))
                wr_jstr!(b, v, to[j], tl[j])
            end
        else
            for j in 1:n
                l = Int(load_be(Int32, v, p))
                p += 4
                j > 1 && wr!(b, UInt8(','))
                wr_jstr!(b, v, p, l)
                p += max(l, 0)
            end
        end
    end
    wr!(b, UInt8(']'))
end

# columns from k: id, slug, title, description, [body], created_at, updated_at, tag_list, favorites_count,
# favorited, username, bio, image, following
function wr_article!(lp::Loop, b::Buf, c::PgConn, k::Int, body::Bool)
    wr!(b, "{\"slug\":")
    wcol!(b, c, k + 1)
    wr!(b, ",\"title\":")
    wcol!(b, c, k + 2)
    wr!(b, ",\"description\":")
    wcol!(b, c, k + 3)
    j = k + 4
    if body
        wr!(b, ",\"body\":")
        wcol!(b, c, j)
        j += 1
    end
    wr!(b, ",\"createdAt\":")
    wts_col!(b, c, j)
    wr!(b, ",\"updatedAt\":")
    wts_col!(b, c, j + 1)
    wr!(b, ",\"tagList\":")
    wr_tags!(lp, b, c, j + 2)
    wr!(b, ",\"favoritesCount\":")
    put_int!(b, col_i64(c, j + 3))
    wr!(b, ",\"favorited\":")
    wbool!(b, col_bool(c, j + 4))
    wr!(b, ",\"author\":{\"username\":")
    wcol!(b, c, j + 5)
    wr!(b, ",\"bio\":")
    wcol_or_null!(b, c, j + 6)
    wr!(b, ",\"image\":")
    wcol_or_null!(b, c, j + 7)
    wr!(b, ",\"following\":")
    wbool!(b, col_bool(c, j + 8))
    wr!(b, "}}")
end

# columns from k: username, bio, image
function wr_profile!(b::Buf, c::PgConn, k::Int, following::Bool)
    wr!(b, "{\"profile\":{\"username\":")
    wcol!(b, c, k)
    wr!(b, ",\"bio\":")
    wcol_or_null!(b, c, k + 1)
    wr!(b, ",\"image\":")
    wcol_or_null!(b, c, k + 2)
    wr!(b, ",\"following\":")
    wbool!(b, following)
    wr!(b, "}}")
end

# columns from k: id, body, created_at, updated_at, username, bio, image
function wr_comment!(b::Buf, c::PgConn, k::Int, following::Bool)
    wr!(b, "{\"id\":")
    put_int!(b, col_i64(c, k))
    wr!(b, ",\"createdAt\":")
    wts_col!(b, c, k + 2)
    wr!(b, ",\"updatedAt\":")
    wts_col!(b, c, k + 3)
    wr!(b, ",\"body\":")
    wcol!(b, c, k + 1)
    wr!(b, ",\"author\":{\"username\":")
    wcol!(b, c, k + 4)
    wr!(b, ",\"bio\":")
    wcol_or_null!(b, c, k + 5)
    wr!(b, ",\"image\":")
    wcol_or_null!(b, c, k + 6)
    wr!(b, ",\"following\":")
    wbool!(b, following)
    wr!(b, "}}")
end

# columns from k: id, username, email, bio, image; then the token (fresh, or the presented one)
function wr_user!(lp::Loop, r::Req, c::PgConn, k::Int, fresh::Bool)
    b = r.out
    wr!(b, "{\"user\":{\"email\":")
    wcol!(b, c, k + 2)
    wr!(b, ",\"username\":")
    wcol!(b, c, k + 1)
    wr!(b, ",\"bio\":")
    wcol_or_null!(b, c, k + 3)
    wr!(b, ",\"image\":")
    wcol_or_null!(b, c, k + 4)
    wr!(b, ",\"token\":\"")
    if fresh
        jwt_issue!(b, lp.jwt, JWT_KEY[], col_i64(c, k), lp.now)
    else
        wr!(b, r.arena.data, r.tok_off, r.tok_len)
    end
    wr!(b, "\"}}")
end
