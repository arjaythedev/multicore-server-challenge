(SELECT decode(string_agg(lpad(to_hex(CASE WHEN i < octet_length(k) THEN get_byte(k, i) ELSE 0 END # 54), 2, '0'), '' ORDER BY i), 'hex') AS ipad,
        decode(string_agg(lpad(to_hex(CASE WHEN i < octet_length(k) THEN get_byte(k, i) ELSE 0 END # 92), 2, '0'), '' ORDER BY i), 'hex') AS opad
   FROM (SELECT CASE WHEN octet_length(convert_to(:secret::text, 'UTF8')) > 64 THEN sha256(convert_to(:secret::text, 'UTF8'))
                     ELSE convert_to(:secret::text, 'UTF8') END AS k) key,
        generate_series(0, 63) AS i)
