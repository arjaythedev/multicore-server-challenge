import { endpoint } from "../../../../../../src/endpoint";
import { deleteComment } from "../../../../../../src/comments";
export const DELETE = endpoint("required", deleteComment);
