// Desktop Freedom's DomainOperationStore (src/main/domains/operation-store.js)
// for the iPhone: the same records, revisions and limits, kept in memory and
// written through the app (Application Support/Agent/domain-operations.json),
// with registration secrets in the Keychain instead of Electron safeStorage.
// Writes are queued; `flush()` resolves once everything saved so far is on
// disk, and the service awaits it before any transaction can be sent.

import { refuse } from './contracts.js';

const MAX_BYTES = 4 * 1024 * 1024;
const randomHex = bytes => Array.from(crypto.getRandomValues(new Uint8Array(bytes)), byte => byte.toString(16).padStart(2, '0')).join('');

export class DomainOperationStore {
  static async open(host) {
    const loaded = await host('loadOperations', {});
    const operations = new Map();
    for (const operation of Array.isArray(loaded?.operations) ? loaded.operations.slice(0, 500) : []) {
      if (!/^domain_[a-f0-9]{24}$/.test(operation?.id ?? '')) continue;
      // A crash after handing off to the signer is never permission to send
      // again. Keep the uncertain marker even if there is no returned hash.
      if (operation.state === 'dispatching') operation.state = 'dispatch_unknown';
      operations.set(operation.id, operation);
    }
    const store = new DomainOperationStore(host, operations);
    for (const operation of operations.values()) {
      if (typeof operation.encryptedSecret !== 'string') continue;
      const stored = await host('readSecret', { handle: operation.encryptedSecret }).catch(() => null);
      if (stored?.secret) store.secrets.set(operation.encryptedSecret, stored.secret);
      store.stored.add(operation.encryptedSecret);
    }
    return store;
  }
  constructor(host, operations) {
    this.host = host;
    this.operations = operations;
    this.secrets = new Map();
    // Secrets in the Keychain: one is written with the first save of its operation,
    // so a plan that fails before it is saved leaves nothing behind.
    this.stored = new Set();
    this.writing = Promise.resolve();
  }
  list() { return structuredClone([...this.operations.values()]); }
  get(id) { return structuredClone(this.operations.get(id) || null); }
  protectSecret(secret) {
    const handle = `secret_${randomHex(12)}`;
    this.secrets.set(handle, secret);
    return handle;
  }
  revealSecret(operation) {
    const secret = this.secrets.get(operation.encryptedSecret);
    if (!/^0x[a-f0-9]{64}$/.test(secret ?? '')) refuse('The saved registration secret could not be recovered.', 'DOMAIN_SECURE_STORAGE');
    return secret;
  }
  // Compare-and-swap: a caller saves the revision it read. A copy read before
  // a slow RPC must never overwrite a newer record, such as a dispatched
  // reveal's transaction hash. Journals written before revisions count as 0.
  save(operation) {
    const revision = operation.revision ?? 0;
    const previous = this.operations.get(operation.id);
    if ((previous?.revision ?? 0) !== revision) refuse('This domain operation changed while it was being checked. Inspect its current status; nothing was overwritten.', 'DOMAIN_CONFLICT');
    const next = new Map(this.operations);
    next.set(operation.id, { ...structuredClone(operation), revision: revision + 1 });
    if (next.size > 500) refuse('Domain operation storage is full. Existing operations can still be inspected.');
    const body = JSON.stringify({ version: 1, operations: [...next.values()] });
    if (new TextEncoder().encode(body).length > MAX_BYTES) refuse('Domain operation storage is full.');
    this.operations = next;
    operation.revision = revision + 1;
    const handle = operation.encryptedSecret;
    if (typeof handle === 'string' && !this.stored.has(handle) && this.secrets.has(handle)) {
      const secret = this.secrets.get(handle);
      this.stored.add(handle);
      this.#queue(() => this.host('saveSecret', { handle, secret }));
    }
    this.#queue(() => this.host('saveOperations', { body }));
    // A finished registration's secret is deleted with its last use (desktop drops encryptedSecret).
    if (previous?.encryptedSecret && !operation.encryptedSecret) {
      const handle = previous.encryptedSecret;
      this.secrets.delete(handle);
      this.stored.delete(handle);
      this.#queue(() => this.host('deleteSecret', { handle }));
    }
  }
  #queue(write) {
    this.writing = this.writing.catch(() => {}).then(write);
  }
  /** Resolves once every save so far is stored; fails if the last write failed. */
  async flush() {
    try {
      await this.writing;
    } catch {
      refuse('Freedom could not store this domain operation. Nothing was sent.', 'DOMAIN_STORAGE');
    }
  }
}
