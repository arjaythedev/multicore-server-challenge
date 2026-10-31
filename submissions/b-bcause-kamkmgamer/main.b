/*
 * B entry point and request router for the Conduit server.
 *
 * BCause exposes B's single machine-word type. The route classifier below is
 * called for every request through the C ABI; it owns the static endpoint
 * matching while C owns PostgreSQL, HTTP parsing, and response execution.
 */
extrn c_server_main;

is_articles(p, n) { return(n == 8 & p[0] == 8315171461236290145); }
is_tags(p, n) { return(n == 4 & (p[0] & 4294967295) == 1936154996); }
is_user(p, n) { return(n == 4 & (p[0] & 4294967295) == 1919251317); }
is_profiles(p, n) { return(n == 8 & p[0] == 8315171486955434608); }
is_users(p, n) { return(n == 5 & (p[0] & 1099511627775) == 495840490357); }
is_feed(p, n) { return(n == 4 & (p[0] & 4294967295) == 1684366694); }
is_favorite(p, n) { return(n == 8 & p[0] == 7310584035346375014); }
is_comments(p, n) { return(n == 8 & p[0] == 8319395793566789475); }
is_follow(p, n) { return(n == 6 & (p[0] & 281474976710655) == 131320444120934); }
is_login(p, n) { return(n == 5 & (p[0] & 1099511627775) == 474214788972); }

b_route(method, segs, nseg) {
    auto p0, n0, p1, n1, p2, n2, p3, n3;
    p0 = segs[0]; n0 = segs[1];
    p1 = segs[2]; n1 = segs[3];
    p2 = segs[4]; n2 = segs[5];
    p3 = segs[6]; n3 = segs[7];

    if (nseg <= 0) return(0);

    if (is_articles(p0, n0)) {
        if (nseg == 1) {
            if (method == 0) return(8);
            if (method == 1) return(10);
            return(0);
        }
        if (n1 == 0) return(0);
        if (nseg == 2) {
            if (method == 0) {
                if (is_feed(p1, n1)) return(9);
                return(11);
            }
            if (method == 2) return(12);
            if (method == 3) return(13);
            return(0);
        }
        if (nseg == 3) {
            if (is_favorite(p2, n2)) {
                if (method == 1) return(14);
                if (method == 3) return(15);
            }
            if (is_comments(p2, n2)) {
                if (method == 0) return(16);
                if (method == 1) return(17);
            }
            return(0);
        }
        if (nseg == 4 & n3 & method == 3) {
            if (is_comments(p2, n2)) return(18);
        }
        return(0);
    }

    if (is_tags(p0, n0)) {
        if (nseg == 1 & method == 0) return(19);
        return(0);
    }

    if (is_user(p0, n0)) {
        if (nseg != 1) return(0);
        if (method == 0) return(3);
        if (method == 2) return(4);
        return(0);
    }

    if (is_profiles(p0, n0)) {
        if (nseg < 2 | n1 == 0) return(0);
        if (nseg == 2) {
            if (method == 0) return(5);
            return(0);
        }
        if (nseg == 3 & is_follow(p2, n2)) {
            if (method == 1) return(6);
            if (method == 3) return(7);
        }
        return(0);
    }

    if (is_users(p0, n0)) {
        if (nseg == 1) {
            if (method == 1) return(1);
            return(0);
        }
        if (nseg == 2 & is_login(p1, n1) & method == 1) return(2);
    }

    return(0);
}

/* Authorization modes match api.c's A_NONE/A_OPTIONAL/A_REQUIRED values. */
b_auth_mode(route) {
    if (route == 5 | route == 8 | route == 11 | route == 16) return(1);
    if (route == 3 | route == 4 | route == 6 | route == 7 | route == 9 | route == 10 |
        route == 12 | route == 13 | route == 14 | route == 15 | route == 17 | route == 18) return(2);
    return(0);
}

main() {
    c_server_main(0, 0);
}
