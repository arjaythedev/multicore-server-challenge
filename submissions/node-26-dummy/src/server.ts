import * as http from "node:http";

import * as handlers from "./handlers.js";
import { HttpError, pool, finishPoolDiagnostics, httpDiagnostics, sendError, type Handler } from "./utils.js";

const host = process.env.HOST ?? "0.0.0.0";
const port = Number(process.env.PORT ?? "3000");

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
    sendError(response, 400, "invalid URL");
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
    httpDiagnostics?.route(response, route.method + ' ' + route.pattern.source);

    try {
      for (const [index, name] of route.parameterNames.entries()) {
        const value = match[index + 1];
        if (value === undefined) {
          sendError(response, 404, "not found");
          return;
        }
        params[name] = decodeURIComponent(value);
      }
    } catch {
      sendError(response, 400, "invalid path encoding");
      return;
    }

    await route.handler({ request, response, url, params });
    return;
  }

  sendError(response, 404, "not found");
};

let shuttingDown = false;
const activeResponses = new Set<http.ServerResponse>();
const pendingHandlers = new Set<Promise<void>>();
const server = http.createServer((request, response) => {
  httpDiagnostics?.begin(response);
  activeResponses.add(response);
  response.once('close', () => activeResponses.delete(response));
  if (shuttingDown) response.shouldKeepAlive = false;
  const pending = routeRequest(request, response).catch((error: unknown) => {
    request.resume();
    const duplicate = error !== null && typeof error === 'object' && 'code' in error && error.code === '23505';
    const status = error instanceof HttpError ? error.status : duplicate ? 422 : 500;
    if (status === 500) console.error(error);

    if (!response.headersSent) {
      sendError(response, status, error instanceof HttpError ? error.message : duplicate ? 'Already exists' : 'Internal server error');
    } else {
      response.destroy(error instanceof Error ? error : undefined);
    }
  });
  pendingHandlers.add(pending);
  void pending.then(() => pendingHandlers.delete(pending), () => pendingHandlers.delete(pending));
});

server.keepAliveTimeout = 75_000;
server.headersTimeout = 80_000;

server.listen(port, host, () => {
  console.log(`dummy app listening on http://${host}:${port}`);
});

const shutdown = (): void => {
  if (shuttingDown) return;
  shuttingDown = true;
  for (const response of activeResponses) response.shouldKeepAlive = false;
  const deadline = setTimeout(() => process.exit(1), 9_000);
  server.close(() => {
    void Promise.allSettled([...pendingHandlers]).then(() => pool.end()).then(() => Promise.all([finishPoolDiagnostics?.(), httpDiagnostics?.finish()])).then(() => {
      clearTimeout(deadline);
      process.exit(0);
    }).catch((error: unknown) => { console.error(error); process.exit(1); });
  });
};

process.once('SIGINT', shutdown);
process.once('SIGTERM', shutdown);
process.once('disconnect', shutdown);
