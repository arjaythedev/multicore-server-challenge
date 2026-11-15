import { endpoint } from "../../../src/endpoint";
import { getCurrent, updateCurrent } from "../../../src/users";
export const GET = endpoint("required", getCurrent);
export const PUT = endpoint("required", updateCurrent);
