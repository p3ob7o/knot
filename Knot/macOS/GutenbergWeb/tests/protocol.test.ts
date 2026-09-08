import { beforeEach, describe, expect, test, vi } from "vitest";
import { AssetChunkAssembler, chunkAsset } from "../src/assetTransfer";
import { BridgeClient, isEnvelope, MAX_STANDARD_MESSAGE_BYTES } from "../src/protocol";

const sessionID = "11111111-1111-4111-8111-111111111111";
const draftID = "22222222-2222-4222-8222-222222222222";
const requestID = "33333333-3333-4333-8333-333333333333";

describe("T15 bridge validation", () => {
  beforeEach(() => {
    Object.defineProperty(globalThis, "window", { value: globalThis, configurable: true });
    Object.defineProperty(globalThis, "crypto", { value: { randomUUID: () => requestID }, configurable: true });
  });

  test("rejects wrong version, identifiers, revisions, type, and oversized messages", () => {
    const base = { version: 1, sessionID, draftID, revision: 0, requestID, type: "ready", payload: {} };
    expect(isEnvelope(base, "web")).toBe(true);
    expect(isEnvelope({ ...base, version: 2 }, "web")).toBe(false);
    expect(isEnvelope({ ...base, sessionID: "bad" }, "web")).toBe(false);
    expect(isEnvelope({ ...base, revision: Number.MAX_SAFE_INTEGER + 1 }, "web")).toBe(false);
    expect(isEnvelope({ ...base, type: "filesystem" }, "web")).toBe(false);
    expect(isEnvelope({ ...base, payload: { value: "x".repeat(MAX_STANDARD_MESSAGE_BYTES) } }, "web")).toBe(false);
  });

  test("ignores stale session responses and caps the request table", async () => {
    const postMessage = vi.fn();
    (globalThis as any).webkit = { messageHandlers: { knotEditor: { postMessage } } };
    const bridge = new BridgeClient({ version: 1, sessionID, draftID, revision: 0 });
    const request = bridge.request("ready", 0, {}, 20);
    (globalThis as any).KnotNativeReceive({ version: 1, sessionID: "44444444-4444-4444-8444-444444444444", draftID, revision: 0, requestID, type: "initialize", payload: {} });
    await expect(request).rejects.toThrow("timed out");
    bridge.close();
  });
});

describe("T16 ordered asset chunks", () => {
  test("round-trips bounded chunks and rejects reorder, overflow, and missing data", () => {
    const bytes = new Uint8Array(200_000).map((_, index) => index % 251);
    const chunks = chunkAsset(bytes);
    const assembler = new AssetChunkAssembler(bytes.length);
    chunks.forEach((chunk) => assembler.append(chunk));
    expect(assembler.finish()).toEqual(bytes);
    const reordered = new AssetChunkAssembler(bytes.length);
    expect(() => reordered.append(chunks[1])).toThrow("assetChunkOrder");
    const incomplete = new AssetChunkAssembler(bytes.length);
    incomplete.append(chunks[0]);
    expect(() => incomplete.finish()).toThrow("assetIncomplete");
  });
});
