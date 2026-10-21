import { SQL } from "bun";

const db_conn = process.env.DATABASE_URL;
if (!db_conn) throw new Error("DATABASE_URL is required");

export const db = new SQL(db_conn, { max: 95 });
