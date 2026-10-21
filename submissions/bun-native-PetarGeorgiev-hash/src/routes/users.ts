import { SQL } from "bun";
import { getUser, getUserById, insertUser, updateUser } from "../db/sql";
import type { ResponseUser } from "../types/types";
import {
  BadBody,
  errorResponse,
  hashPasswod,
  issueToken,
  optString,
  readWrapper,
  reqString,
  res,
} from "../utils/utils";
import { authenticate } from "../auth/auth";

const userResponse = (user: ResponseUser, token: string): ResponseUser => {
  return {
    username: user.username,
    bio: user.bio,
    image: user.image,
    email: user.email,
    token: token,
  };
};

export const userRoute = {
  GET: async (req: Request): Promise<Response> => {
    const auth = await authenticate(req, true);
    if (auth instanceof Response) return auth;
    const { viewerId, token } = auth;
    if (!token) throw errorResponse(401, "Unauth");
    const [user] = await getUserById(viewerId);
    if (!user) return errorResponse(401, "Unauth");
    return res({ user: userResponse(user, token) }, 200);
  },
  PUT: async (req: Request): Promise<Response> => {
    const auth = await authenticate(req, true);
    if (auth instanceof Response) return auth;

    const { viewerId, token } = auth;
    if (!token) throw errorResponse(401, "Unauth");
    let username: string | null,
      email: string | null,
      password: string | null,
      bio: string | null,
      image: string | null;
    try {
      const m = await readWrapper(req, "user");
      email = optString(m, "email", true);
      username = optString(m, "username", true);
      password = optString(m, "password", true);
      bio = optString(m, "bio");
      image = optString(m, "image");
      if (password && password.length > 72)
        return errorResponse(422, "Password is too long");
    } catch (e) {
      if (e instanceof BadBody) return errorResponse(422, "Invalid req body");
      throw e;
    }
    let password_hash = null;
    if (password) {
      password_hash = await hashPasswod(password);
    }
    let user;
    try {
      [user] = await updateUser(
        viewerId,
        email,
        username,
        password_hash,
        bio,
        image,
      );
    } catch {
      return errorResponse(422, "Unique violation");
    }
    return res({ user: userResponse(user, token) }, 200);
  },
};

export const usersRoute = {
  POST: async (req: Request): Promise<Response> => {
    let user;
    let username: string, email: string, password: string;
    try {
      const m = await readWrapper(req, "user");
      username = reqString(m, "username");
      email = reqString(m, "email");
      password = reqString(m, "password");
      if (password.length > 72)
        return errorResponse(422, "Password is too long");
    } catch (e) {
      if (e instanceof BadBody) return errorResponse(422, "Invalid req body");
      throw e;
    }
    const password_hash = await hashPasswod(password);
    try {
      [user] = await insertUser(username, email, password_hash);
    } catch (error) {
      if (error instanceof SQL.PostgresError) {
        error.code == "23505";
        return errorResponse(422, "Username or email already taken");
      }
    }
    const token = await issueToken(user.id);
    return res({ user: userResponse(user, token) }, 201);
  },
};

export const loginRoute = {
  POST: async (req: Request): Promise<Response> => {
    let user;
    let email: string, password: string;
    try {
      const m = await readWrapper(req, "user");
      email = reqString(m, "email");
      password = reqString(m, "password");
      if (password.length > 72)
        return errorResponse(422, "Password is too long");
    } catch (e) {
      if (e instanceof BadBody) return errorResponse(422, "Invalid req body");
      throw e;
    }
    try {
      [user] = await getUser(email);
      const isMatch = await Bun.password.verify(password, user.password_hash);
      if (!isMatch) throw new Error();
    } catch (error) {
      return errorResponse(401, "Something went wrong");
    }
    const token = await issueToken(user.id);
    return res({ user: userResponse(user, token) }, 200);
  },
};
