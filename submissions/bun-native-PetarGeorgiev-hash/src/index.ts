import { getTags } from "./db/sql";
import {
  articleCommentRoute,
  articleCommentsRoute,
  articleFavoriteRoute,
  articleRoute,
  articleRouteFeed,
  articleRouteSlug,
} from "./routes/articles";
import { profileRoute } from "./routes/profiles";
import { loginRoute, userRoute, usersRoute } from "./routes/users";

const host = process.env.HOST || "0.0.0.0";
const port = process.env.PORT || 80;

const server = Bun.serve({
  port: port,
  hostname: host,
  idleTimeout: 75,
  routes: {
    "/api/tags": async () => {
      const rows = await getTags();
      return Response.json({ tags: rows.map((row: any) => row.name) });
    },
    "/api/user": userRoute,
    "/api/users": usersRoute,
    "/api/users/login": loginRoute,
    "/api/profiles/:username": profileRoute,
    "/api/profiles/:username/follow": profileRoute,
    "/api/articles": articleRoute,
    "/api/articles/feed": articleRouteFeed,
    "/api/articles/:slug/favorite": articleFavoriteRoute,
    "/api/articles/:slug/comments": articleCommentsRoute,
    "/api/articles/:slug/comments/:id": articleCommentRoute,
    "/api/articles/:slug": articleRouteSlug,
  },
});

console.log(`Listenign on ${server.url}`);
