(SELECT decode(:hmac_ipad::text, 'hex') AS ipad, decode(:hmac_opad::text, 'hex') AS opad)
