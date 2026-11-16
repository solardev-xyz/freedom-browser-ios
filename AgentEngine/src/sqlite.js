// A SQLite database in the app, for Pi's portable SQLite storage
// (`SqliteDatabase` from @earendil-works/chord/sqlite). Every statement runs
// in Swift (`AgentDatabase.swift`) on one connection to a file the app owns;
// this side only keeps Pi's ordering rules: a transaction holds the database
// until it commits or rolls back, and everything else waits behind it.

import { request } from "./bridge.js";

/** Opens (creating it if needed) the app's database `name`. */
export async function openAppDatabase(name) {
	await request("sql", "open", { name });
	return new AppSqliteDatabase();
}

/** Deletes the app's database `name`; it must not be open. */
export function wipeAppDatabase(name) {
	return request("sql", "wipe", { name });
}

class Executor {
	exec(sql) {
		return this.call("exec", { sql });
	}
	async run(sql, ...params) {
		await this.call("run", { sql, params: encode(params) });
	}
	runCounted(sql, ...params) {
		return this.call("run", { sql, params: encode(params) });
	}
	async get(sql, ...params) {
		const rows = await this.call("all", { sql, params: encode(params), limit: 1 });
		return rows[0] === undefined ? undefined : decodeRow(rows[0]);
	}
	async all(sql, ...params) {
		const rows = await this.call("all", { sql, params: encode(params) });
		return rows.map(decodeRow);
	}
}

class Transaction extends Executor {
	active = true;
	call(method, params) {
		if (!this.active) return Promise.reject(new Error("SQLite transaction handle is no longer active"));
		return request("sql", method, params);
	}
}

class AppSqliteDatabase extends Executor {
	#tail = Promise.resolve();
	#closed = false;

	// One operation at a time, in call order; a transaction holds the line until it ends.
	#serial(operation) {
		const result = this.#tail.then(() => {
			if (this.#closed) throw new Error("The database is closed");
			return operation();
		});
		this.#tail = result.then(
			() => {},
			() => {},
		);
		return result;
	}

	call(method, params) {
		return this.#serial(() => request("sql", method, params));
	}

	transaction(callback) {
		return this.#serial(async () => {
			await request("sql", "exec", { sql: "BEGIN IMMEDIATE" });
			const transaction = new Transaction();
			try {
				const result = await callback(transaction);
				transaction.active = false;
				await request("sql", "exec", { sql: "COMMIT" });
				return result;
			} catch (error) {
				transaction.active = false;
				try {
					await request("sql", "exec", { sql: "ROLLBACK" });
				} catch (rollbackError) {
					throw new AggregateError([error, rollbackError], "SQLite transaction failed and rollback failed");
				}
				throw error;
			}
		});
	}

	close() {
		return this.#serial(async () => {
			this.#closed = true;
			await request("sql", "close", {});
		});
	}
}

// Message handlers carry JSON-like values: tag what JSON can't tell apart.
function encode(params) {
	return params.map((value) => {
		if (value === null || value === undefined) return { t: "null" };
		if (typeof value === "bigint") return { t: "int", v: value.toString() };
		if (typeof value === "number") return Number.isInteger(value) ? { t: "int", v: String(value) } : { t: "real", v: value };
		if (typeof value === "string") return { t: "text", v: value };
		if (value instanceof Uint8Array) return { t: "blob", v: toBase64(value) };
		throw new TypeError(`Unsupported SQLite value: ${typeof value}`);
	});
}

// Swift sends BLOB columns as { $blob: base64 }; everything else as plain JSON.
function decodeRow(row) {
	for (const key in row) {
		const value = row[key];
		if (value !== null && typeof value === "object" && typeof value.$blob === "string") row[key] = fromBase64(value.$blob);
	}
	return row;
}

function toBase64(bytes) {
	let binary = "";
	for (let i = 0; i < bytes.length; i += 0x8000) binary += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
	return btoa(binary);
}

function fromBase64(text) {
	const binary = atob(text);
	const bytes = new Uint8Array(binary.length);
	for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
	return bytes;
}
