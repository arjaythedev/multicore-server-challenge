import { endpoint } from "../../../../../src/endpoint";
import { createComment, listComments } from "../../../../../src/comments";
export const GET = endpoint("optional", listComments);
export const POST = endpoint("required", createComment);
