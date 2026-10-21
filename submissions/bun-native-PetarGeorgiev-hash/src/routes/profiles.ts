import { authenticate } from "../auth/auth";
import {
  checkProfile,
  followProfile,
  getProfile,
  unFollowProfile,
} from "../db/sql";
import type { ProfileResponse } from "../types/types";
import { errorResponse, res } from "../utils/utils";

const profileResponse = (
  profile: ProfileResponse,
): Omit<ProfileResponse, "id"> => {
  return {
    username: profile.username,
    bio: profile.bio,
    image: profile.image,
    following: profile.following,
  };
};

export const profileRoute = {
  GET: async (
    req: Bun.BunRequest<"/api/profiles/:username">,
  ): Promise<Response> => {
    const auth = await authenticate(req, false);
    if (auth instanceof Response) return auth;
    const { viewerId } = auth;
    const { username } = req.params;
    const [profile] = await getProfile(viewerId, username);
    if (!profile) return errorResponse(404, "Not Found");
    return res({ profile: profileResponse(profile) }, 200);
  },
  POST: async (
    req: Bun.BunRequest<"/api/profiles/:username/follow">,
  ): Promise<Response> => {
    const auth = await authenticate(req, true);
    if (auth instanceof Response) return auth;
    const { username } = req.params;
    const { viewerId } = auth;
    let profile;
    try {
      const [user] = await checkProfile(username);
      if (!user) return errorResponse(404, "Not Found");
      await followProfile(viewerId, user.id);
      [profile] = await getProfile(viewerId, username);
    } catch {
      return errorResponse(422, "Something went wrong");
    }
    return res({ profile: profileResponse(profile) }, 200);
  },
  DELETE: async (
    req: Bun.BunRequest<"/api/profiles/:username/follow">,
  ): Promise<Response> => {
    const auth = await authenticate(req, true);
    if (auth instanceof Response) return auth;
    const { username } = req.params;
    const { viewerId } = auth;
    let profile;
    try {
      const [user] = await checkProfile(username);
      if (!user) return errorResponse(404, "Not Found");
      await unFollowProfile(viewerId, user.id);
      [profile] = await getProfile(viewerId, username);
    } catch {
      return errorResponse(422, "Something went wrong");
    }
    return res({ profile: profileResponse(profile) }, 200);
  },
};
