import { errorResponse } from "../../../src/http";
const missing = () => errorResponse(404, "Not found");
export { missing as GET, missing as POST, missing as PUT, missing as PATCH, missing as DELETE, missing as OPTIONS };
