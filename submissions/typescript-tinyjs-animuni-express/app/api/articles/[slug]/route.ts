import { endpoint } from "../../../../src/endpoint";
import { deleteArticle, getArticle, updateArticle } from "../../../../src/articles";
export const GET = endpoint("optional", getArticle);
export const PUT = endpoint("required", updateArticle);
export const DELETE = endpoint("required", deleteArticle);
