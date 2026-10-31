import * as http from "node:http";

import * as handlers from "./handlers.js";
import type { Handler } from "./handlers.js";

const host = process.env.HOST ?? "0.0.0.0";
const port = Number.parseInt(process.env.PORT ?? "3000", 10);

if (!Number.isInteger(port) || port < 1 || port > 65_535) {
  throw new Error("PORT must be an integer between 1 and 65535");
}

interface Route {
  readonly method: string;
  readonly pattern: RegExp;
  readonly parameterNames: readonly string[];
  readonly handler: Handler;
}

const routes: readonly Route[] = [
  { method: "POST", pattern: /^\/api\/users\/?$/, parameterNames: [], handler: handlers.registerUser },
  { method: "POST", pattern: /^\/api\/users\/login\/?$/, parameterNames: [], handler: handlers.loginUser },
  { method: "GET", pattern: /^\/api\/user\/?$/, parameterNames: [], handler: handlers.getCurrentUser },
  { method: "PUT", pattern: /^\/api\/user\/?$/, parameterNames: [], handler: handlers.updateCurrentUser },

  { method: "GET", pattern: /^\/api\/profiles\/([^/]+)\/?$/, parameterNames: ["username"], handler: handlers.getProfile },
  { method: "POST", pattern: /^\/api\/profiles\/([^/]+)\/follow\/?$/, parameterNames: ["username"], handler: handlers.followProfile },
  { method: "DELETE", pattern: /^\/api\/profiles\/([^/]+)\/follow\/?$/, parameterNames: ["username"], handler: handlers.unfollowProfile },

  { method: "GET", pattern: /^\/api\/articles\/?$/, parameterNames: [], handler: handlers.listArticles },
  { method: "POST", pattern: /^\/api\/articles\/?$/, parameterNames: [], handler: handlers.createArticle },
  { method: "GET", pattern: /^\/api\/articles\/feed\/?$/, parameterNames: [], handler: handlers.getArticleFeed },
  { method: "GET", pattern: /^\/api\/articles\/([^/]+)\/?$/, parameterNames: ["slug"], handler: handlers.getArticle },
  { method: "PUT", pattern: /^\/api\/articles\/([^/]+)\/?$/, parameterNames: ["slug"], handler: handlers.updateArticle },
  { method: "DELETE", pattern: /^\/api\/articles\/([^/]+)\/?$/, parameterNames: ["slug"], handler: handlers.deleteArticle },

  { method: "POST", pattern: /^\/api\/articles\/([^/]+)\/favorite\/?$/, parameterNames: ["slug"], handler: handlers.favoriteArticle },
  { method: "DELETE", pattern: /^\/api\/articles\/([^/]+)\/favorite\/?$/, parameterNames: ["slug"], handler: handlers.unfavoriteArticle },

  { method: "GET", pattern: /^\/api\/articles\/([^/]+)\/comments\/?$/, parameterNames: ["slug"], handler: handlers.listComments },
  { method: "POST", pattern: /^\/api\/articles\/([^/]+)\/comments\/?$/, parameterNames: ["slug"], handler: handlers.createComment },
  { method: "DELETE", pattern: /^\/api\/articles\/([^/]+)\/comments\/([^/]+)\/?$/, parameterNames: ["slug", "id"], handler: handlers.deleteComment },

  { method: "GET", pattern: /^\/api\/tags\/?$/, parameterNames: [], handler: handlers.listTags },
];

const routeRequest = async (
  request: http.IncomingMessage,
  response: http.ServerResponse,
): Promise<void> => {
  let url: URL;

  try {
    url = new URL(request.url ?? "/", "http://localhost");
  } catch {
    handlers.sendError(response, 400, "invalid URL");
    return;
  }

  for (const route of routes) {
    if (request.method !== route.method) {
      continue;
    }

    const match = route.pattern.exec(url.pathname);
    if (match === null) {
      continue;
    }

    const params: Record<string, string> = {};

    try {
      for (const [index, name] of route.parameterNames.entries()) {
        const value = match[index + 1];
        if (value === undefined) {
          handlers.sendError(response, 404, "not found");
          return;
        }
        params[name] = decodeURIComponent(value);
      }
    } catch {
      handlers.sendError(response, 400, "invalid path encoding");
      return;
    }

    await route.handler({ request, response, url, params });
    return;
  }

  handlers.sendError(response, 404, "not found");
};

const server = http.createServer((request, response) => {
  void routeRequest(request, response).catch((error: unknown) => {
    console.error(error);

    if (!response.headersSent) {
      handlers.sendError(response, 500, "internal server error");
    } else {
      response.destroy(error instanceof Error ? error : undefined);
    }
  });
});

server.listen(port, host, () => {
  console.log(`dummy app listening on http://${host}:${port}`);
});

const shutdown = (signal: NodeJS.Signals): void => {
  console.log(`${signal}: shutting down`);
  server.close(() => process.exit(0));
};

process.once("SIGINT", () => shutdown("SIGINT"));
process.once("SIGTERM", () => shutdown("SIGTERM"));
