import { endpoint } from "../../../../../src/endpoint";
import { favorite } from "../../../../../src/articles";
export const POST = endpoint("required", favorite);
export const DELETE = endpoint("required", favorite);
