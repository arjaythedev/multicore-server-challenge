package challenge.app;

import java.nio.charset.StandardCharsets;
import java.util.Objects;

import challenge.Jwt;
import challenge.app.Conduit.Services;
import challenge.app.Inputs.Body;
import challenge.app.Inputs.Invalid;
import challenge.app.Inputs.Params;
import challenge.servlet.Container;
import challenge.servlet.Request;
import challenge.servlet.Response;

public final class InputsTest {
    private static Request request(String method, String target, String body) {
        byte[] bytes = (method + " " + target + " HTTP/1.1\r\n\r\n" + body).getBytes(StandardCharsets.UTF_8);
        Request r = new Request(null);
        r.data = bytes;
        r.pathStart = method.length() + 1;
        int q = target.indexOf('?');
        r.pathEnd = r.pathStart + (q < 0 ? target.length() : q);
        r.queryStart = q < 0 ? -1 : r.pathStart + q + 1;
        r.queryEnd = q < 0 ? -1 : r.pathStart + target.length();
        r.bodyStart = bytes.length - body.getBytes(StandardCharsets.UTF_8).length;
        r.bodyLength = bytes.length - r.bodyStart;
        return r;
    }

    private static Response response(Container container, String method, String target,
            String body)
            throws Exception {
        Request req = request(method, target, body);
        Response res = new Response();
        req.init(res);
        res.init(req, container);
        container.service(req, res);
        return res;
    }

    private static int status(Container container, String method, String target,
            String body)
            throws Exception {
        return response(container, method, target, body).status;
    }

    private static void check(boolean b) {
        if (!b) {
            throw new AssertionError();
        }
    }

    private static void invalid(String json) throws Exception {
        try {
            Body body = Inputs.body(request("POST", "/api/users", json), "user");
            Inputs.field(body, "username", true, true);
            throw new AssertionError(json);
        } catch (Invalid expected) {
        }
    }

    public static void main(String[] args) throws Exception {
        Body body = Inputs.body(request("POST", "/api/users", "{\"extra\":[{},1],\"user\":{\"username\":\"a\\u0062\",\"bio\":null}}"), "user");
        check(Inputs.field(body, "username", true, true).equals("ab"));
        check(Inputs.field(body, "bio", false, false) == null);
        check(new String(
                body.get("username").bytes(),
                body.get("username").offset(),
                body.get("username").length(),
                StandardCharsets.UTF_8)
                .equals("\"a\\u0062\""));
        invalid("{}");
        invalid("{\"user\":{\"username\":\"\"}}");
        invalid("{\"user\":{\"username\":123}}");
        invalid("{\"user\":{\"username\":\"a\",\"username\":\"b\"}}");
        invalid("{\"other\":{\"user\":{\"username\":\"x\"}}}");
        invalid("{\"user\":{\"username\":null}}");
        invalid("{\"user\":{\"username\":false}}");
        body = Inputs.body(request("POST", "/api/users", "{\"user\":{\"username\":\"한\\n\\\"\\ud83d\\ude00\"}}"), "user");
        check(Inputs.field(body, "username", true, true).equals("한\n\"😀"));
        Request page = request("GET", "/api/articles?limit=05&offset=005", "");
        check(Inputs.page(page, "limit", 20, 1, 100) == 5);
        check(Inputs.page(page, "offset", 0, 0, Integer.MAX_VALUE) == 5);
        for (String value : new String[] {"0", "101", "%2B5", "%205", "1.5", "999999999999"}) {
            try {
                Inputs.page(request("GET", "/api/articles?limit=" + value, ""),
                        "limit", 20, 1, 100);
                throw new AssertionError(value);
            } catch (Invalid expected) {
            }
        }
        Params params = new Params();
        for (String query : new String[] {"%6cimit=05&offset=7&tag=a%2Bb+c&author=%ED%95%9C&favorited=x",
                "tag=&tag=second&author=%FF", "x=%C3%28&limit=3", "offset=2147483647"}) {
            Request r = request("GET", "/api/articles?" + query, "");
            params.parse(r);
            String[] names = {"limit", "offset", "tag", "author", "favorited"};
            for (int j = 0; j < names.length; j++) {
                String expected = r.getParameter(names[j]);
                String actual = params.length(j) < 0 ? null : new String(params.bytes(), params.offset(j), params.length(j),
                        StandardCharsets.UTF_8);
                check(Objects.equals(expected, actual));
            }
        }
        for (String query : new String[] {"limit=0", "limit=101", "limit=%2B5", "limit=999999999999", "x=%Q0"}) {
            try {
                params.parse(request("GET", "/api/articles?" + query, ""));
                params.page(0, 20, 1, 100);
                throw new AssertionError(query);
            } catch (Invalid expected) {
            }
        }
        Container container = Conduit.container(new Services(null, null, "secret"));
        check(status(container, "POST", "/api/users", "{}") == 422);
        check(status(container, "PUT", "/api/user", "{}") == 401);
        check(status(container, "GET", "/api/articles/feed", "") == 401);
        check(status(container, "GET", "/api/articles?limit=0", "") == 422);
        check(status(container, "GET", "/api/articles?offset=2147483648", "") == 422);
        check(status(container, "GET", "/api/articles//comments", "") == 404);
        check(status(container, "DELETE", "/api/user", "") == 405);
        Response res = response(container, "GET", "/api/nothing", "");
        check(res.status == 404 && new String(
                res.jsonOut().bytes(),
                0,
                res.jsonOut().length(),
                StandardCharsets.UTF_8)
                .equals("{\"errors\":{\"body\":[\"not found\"]}}"));
        Request auth = request("GET", "/api/user", "");
        check(Inputs.viewer(auth, new Jwt("secret"), false) == 0);
        check(Inputs.viewer(auth, new Jwt("secret"), true) == -1);
        System.out.println("challenge.app.InputsTest passed");
    }
}
