import { authenticate, type Auth, type AuthMode } from "./auth";
import { errorResponse, HttpError, type Context } from "./http";

type Handler = (request: Request, context: Context, auth: Auth) => Promise<Response>;

export function endpoint(mode: AuthMode, handle: Handler) {
  return async (request: Request, context: Context) => {
    try { return await handle(request, context, authenticate(request, mode)); }
    catch (error) {
      if (error instanceof HttpError) return errorResponse(error.status, error.message);
      const code = (error as { errno?: string; code?: string })?.errno ?? (error as { code?: string })?.code;
      if (code === "23505") return errorResponse(422, "Value already exists");
      if (code === "23503") return errorResponse(422, "Related resource no longer exists");
      if (code === "22P02" || code === "22021") return errorResponse(422, "Invalid value");
      // Database messages can include submitted values; log codes without request data.
      console.error("Request failed", code ?? (error instanceof Error ? error.name : "UnknownError"));
      return errorResponse(500, "Internal server error");
    }
  };
}
