import { integer, text } from 'drizzle-orm/sqlite-core';
import { v7 as uuidv7 } from 'uuid';

/** UUIDv7 primary key: time-sortable, so `ORDER BY id DESC` == newest first. */
export const pkUuid = () => text('id').primaryKey().$defaultFn(() => uuidv7());

/** Epoch milliseconds, UTC. */
export const ts = (name: string) => integer(name);
export const tsNow = (name: string) =>
  integer(name).notNull().$defaultFn(() => Date.now());

/** SQLite has no boolean: 0/1. */
export const bool = (name: string, def: boolean) =>
  integer(name, { mode: 'boolean' }).notNull().default(def);

export const newId = uuidv7;
