export const PROTOCOL_VERSION = 1 as const;
export const MAX_STANDARD_MESSAGE_BYTES = 256 * 1024;
export const MAX_PENDING_REQUESTS = 32;
export const MAX_MARKDOWN_BYTES = 8 * 1024 * 1024;
export const MAX_BLOCK_JSON_BYTES = 16 * 1024 * 1024;
export const MAX_NODE_COUNT = 20_000;
export const MAX_DOCUMENT_DEPTH = 64;
export const MAX_ASSET_CHUNK_BYTES = 176 * 1024;

export type WebMessageType =
  | "ready"
  | "checkpoint"
  | "checkpointBegin"
  | "checkpointChunk"
  | "checkpointEnd"
  | "saveRequested"
  | "assetPickerRequested"
  | "assetImportBegin"
  | "assetImportChunk"
  | "assetImportEnd"
  | "openExternal"
  | "editorError"
  | "initializeChunkRequested";

export type NativeMessageType =
  | "initialize"
  | "checkpointAck"
  | "saveAccepted"
  | "saveResult"
  | "assetImportResult"
  | "assetPickerResult"
  | "command"
  | "recoverableError"
  | "initializeChunk";

export type Envelope<T extends string = string, P = unknown> = {
  version: typeof PROTOCOL_VERSION;
  sessionID: string;
  draftID: string;
  revision: number;
  requestID: string;
  type: T;
  payload: P;
};

export type Bootstrap = {
  version: typeof PROTOCOL_VERSION;
  sessionID: string;
  draftID: string;
  revision: number;
};

export type InitializeTransferPayload = {
  buildID: string;
  transferID: string;
  totalBytes: number;
  sha256: string;
  chunkCount: number;
  limits: { markdownBytes: number; blockJSONBytes: number; assetChunkBytes: number };
};

export type InitializePayload = {
  markdown: string;
  blocksJSON?: string | null;
  opaqueSourcesJSON?: string | null;
  buildID: string;
  assetIDs?: string[];
  limits: {
    markdownBytes: number;
    blockJSONBytes: number;
    assetChunkBytes: number;
  };
};

export type CheckpointPayload = {
  baseRevision: number;
  nextRevision: number;
  markdown: string;
  blocksJSON: string;
  opaqueSourcesJSON: string;
  selectedRange: { location: number; length: number } | null;
  assetIDs: string[];
};

export type BridgeError = { code: string; message: string; retryable: boolean };

const uuidPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const webTypes = new Set<WebMessageType>([
  "ready", "checkpoint", "checkpointBegin", "checkpointChunk", "checkpointEnd",
  "saveRequested", "assetPickerRequested", "assetImportBegin", "assetImportChunk", "assetImportEnd",
  "openExternal", "editorError", "initializeChunkRequested",
]);
const nativeTypes = new Set<NativeMessageType>([
  "initialize", "checkpointAck", "saveAccepted", "saveResult",
  "assetImportResult", "assetPickerResult", "command", "recoverableError", "initializeChunk",
]);

export function encodedSize(value: unknown): number {
  return new TextEncoder().encode(JSON.stringify(value)).byteLength;
}

export function boundedJSONShape(value: unknown, maxDepth = MAX_DOCUMENT_DEPTH, maxNodes = MAX_NODE_COUNT): boolean {
  const stack: Array<{ value: unknown; depth: number }> = [{ value, depth: 0 }];
  let nodes = 0;
  while (stack.length > 0) {
    const current = stack.pop()!;
    nodes += 1;
    if (nodes > maxNodes || current.depth > maxDepth) return false;
    if (Array.isArray(current.value)) {
      for (const child of current.value) stack.push({ value: child, depth: current.depth + 1 });
    } else if (current.value !== null && typeof current.value === "object") {
      for (const child of Object.values(current.value as Record<string, unknown>)) {
        stack.push({ value: child, depth: current.depth + 1 });
      }
    }
  }
  return true;
}

export function isEnvelope(value: unknown, direction: "web" | "native"): value is Envelope {
  if (value === null || typeof value !== "object" || !boundedJSONShape(value)) return false;
  const item = value as Record<string, unknown>;
  if (item.version !== PROTOCOL_VERSION || typeof item.type !== "string") return false;
  if (!uuidPattern.test(String(item.sessionID)) || !uuidPattern.test(String(item.draftID))) return false;
  if (!uuidPattern.test(String(item.requestID))) return false;
  if (!Number.isSafeInteger(item.revision) || Number(item.revision) < 0) return false;
  if (encodedSize(value) > MAX_STANDARD_MESSAGE_BYTES) return false;
  return direction === "web"
    ? webTypes.has(item.type as WebMessageType)
    : nativeTypes.has(item.type as NativeMessageType);
}

type HostHandler = { postMessage(message: unknown): void };

declare global {
  interface Window {
    KnotBootstrap?: Bootstrap;
    KnotNativeReceive?: (message: unknown) => void;
    KnotCheckpointForClose?: () => Promise<number>;
    webkit?: { messageHandlers?: { knotEditor?: HostHandler } };
  }
}

export class BridgeClient {
  readonly bootstrap: Bootstrap;
  private pending = new Map<string, {
    resolve: (message: Envelope) => void;
    reject: (error: Error) => void;
    timer: number;
  }>();
  private listeners = new Set<(message: Envelope) => void>();

  constructor(bootstrap: Bootstrap) {
    if (bootstrap.version !== PROTOCOL_VERSION || !uuidPattern.test(bootstrap.sessionID)
      || !uuidPattern.test(bootstrap.draftID) || !Number.isSafeInteger(bootstrap.revision)) {
      throw new Error("Invalid native bootstrap");
    }
    this.bootstrap = bootstrap;
    window.KnotNativeReceive = (value: unknown) => this.receive(value);
  }

  onMessage(listener: (message: Envelope) => void): () => void {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  }

  send<T extends WebMessageType>(type: T, revision: number, payload: unknown, requestID = crypto.randomUUID()): string {
    const envelope: Envelope<T> = {
      version: PROTOCOL_VERSION,
      sessionID: this.bootstrap.sessionID,
      draftID: this.bootstrap.draftID,
      revision,
      requestID,
      type,
      payload,
    };
    if (!isEnvelope(envelope, "web")) throw new Error("Outbound bridge message is invalid or oversized");
    const handler = window.webkit?.messageHandlers?.knotEditor;
    if (!handler) throw new Error("Native bridge unavailable");
    handler.postMessage(envelope);
    return requestID;
  }

  request<T extends WebMessageType>(type: T, revision: number, payload: unknown, timeoutMS = 10_000): Promise<Envelope> {
    if (this.pending.size >= MAX_PENDING_REQUESTS) return Promise.reject(new Error("Too many pending bridge requests"));
    const requestID = crypto.randomUUID();
    return new Promise((resolve, reject) => {
      const timer = window.setTimeout(() => {
        this.pending.delete(requestID);
        reject(new Error("Native bridge request timed out"));
      }, timeoutMS);
      this.pending.set(requestID, { resolve, reject, timer });
      try {
        this.send(type, revision, payload, requestID);
      } catch (error) {
        window.clearTimeout(timer);
        this.pending.delete(requestID);
        reject(error);
      }
    });
  }

  close(): void {
    for (const request of this.pending.values()) {
      window.clearTimeout(request.timer);
      request.reject(new Error("Editor session closed"));
    }
    this.pending.clear();
    this.listeners.clear();
    delete window.KnotNativeReceive;
  }

  private receive(value: unknown): void {
    if (!isEnvelope(value, "native")) return;
    if (value.sessionID !== this.bootstrap.sessionID || value.draftID !== this.bootstrap.draftID) return;
    const request = this.pending.get(value.requestID);
    if (request) {
      window.clearTimeout(request.timer);
      this.pending.delete(value.requestID);
      request.resolve(value);
    }
    for (const listener of this.listeners) listener(value);
  }
}
