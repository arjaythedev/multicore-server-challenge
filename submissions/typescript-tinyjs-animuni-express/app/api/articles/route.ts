import { endpoint } from "../../../src/endpoint";
import { createArticle, listArticles } from "../../../src/articles";
export const GET = endpoint("optional", listArticles);
export const POST = endpoint("required", createArticle);
