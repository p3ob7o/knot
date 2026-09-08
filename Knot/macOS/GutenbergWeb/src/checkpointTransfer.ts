import { base64ToBytes, bytesToBase64, sha256Hex } from "./assetTransfer";
import {
  boundedJSONShape, BridgeClient, CheckpointPayload, encodedSize, Envelope, InitializePayload, InitializeTransferPayload,
  MAX_ASSET_CHUNK_BYTES, MAX_BLOCK_JSON_BYTES, MAX_MARKDOWN_BYTES,
} from "./protocol";

const MAX_TRANSFER_BYTES = MAX_MARKDOWN_BYTES + MAX_BLOCK_JSON_BYTES;

export async function resolveInitialize(
  bridge: BridgeClient,
  revision: number,
  response: Envelope,
): Promise<InitializePayload> {
  const payload = response.payload as Partial<InitializePayload & InitializeTransferPayload>;
  if (typeof payload.markdown === "string") return payload as InitializePayload;
  if (typeof payload.transferID !== "string" || typeof payload.totalBytes !== "number"
    || payload.totalBytes <= 0 || payload.totalBytes > MAX_TRANSFER_BYTES
    || typeof payload.sha256 !== "string" || !/^[0-9a-f]{64}$/i.test(payload.sha256)
    || typeof payload.chunkCount !== "number" || !Number.isSafeInteger(payload.chunkCount)
    || payload.chunkCount <= 0 || payload.chunkCount > Math.ceil(MAX_TRANSFER_BYTES / MAX_ASSET_CHUNK_BYTES)) {
    throw new Error("Invalid initialization transfer");
  }
  const result = new Uint8Array(payload.totalBytes);
  let offset = 0;
  for (let sequence = 0; sequence < payload.chunkCount; sequence += 1) {
    const chunkResponse = await bridge.request("initializeChunkRequested", revision, {
      transferID: payload.transferID, sequence,
    });
    const chunk = chunkResponse.payload as { sequence?: number; dataBase64?: string; isLast?: boolean };
    if (chunk.sequence !== sequence || typeof chunk.dataBase64 !== "string") throw new Error("Invalid initialization chunk");
    const bytes = base64ToBytes(chunk.dataBase64);
    if (bytes.byteLength === 0 || bytes.byteLength > MAX_ASSET_CHUNK_BYTES || offset + bytes.byteLength > result.byteLength) {
      throw new Error("Invalid initialization chunk size");
    }
    result.set(bytes, offset);
    offset += bytes.byteLength;
    if (chunk.isLast !== (sequence === payload.chunkCount - 1)) throw new Error("Invalid initialization completion");
  }
  if (offset !== result.byteLength || await sha256Hex(result) !== payload.sha256.toLowerCase()) {
    throw new Error("Initialization integrity check failed");
  }
  const decoded = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(result)) as InitializePayload;
  if (!boundedJSONShape(decoded) || typeof decoded.markdown !== "string"
    || new TextEncoder().encode(decoded.markdown).byteLength > MAX_MARKDOWN_BYTES
    || new TextEncoder().encode((decoded.blocksJSON ?? "") + (decoded.opaqueSourcesJSON ?? "")).byteLength > MAX_BLOCK_JSON_BYTES) {
    throw new Error("Initialization document exceeds its limits");
  }
  return decoded;
}

export async function checkpointRequest(
  bridge: BridgeClient,
  revision: number,
  payload: CheckpointPayload,
): Promise<Envelope> {
  if (new TextEncoder().encode(payload.markdown).byteLength > MAX_MARKDOWN_BYTES) throw new Error("Markdown exceeds the 8 MiB limit");
  if (new TextEncoder().encode(payload.blocksJSON + payload.opaqueSourcesJSON).byteLength > MAX_BLOCK_JSON_BYTES) throw new Error("Block data exceeds the 16 MiB limit");
  const ordinaryEnvelope = {
    version: 1, sessionID: bridge.bootstrap.sessionID, draftID: bridge.bootstrap.draftID,
    revision, requestID: crypto.randomUUID(), type: "checkpoint", payload,
  };
  if (encodedSize(ordinaryEnvelope) <= 256 * 1024) return bridge.request("checkpoint", revision, payload);

  const bytes = new TextEncoder().encode(JSON.stringify(payload));
  if (bytes.byteLength > MAX_TRANSFER_BYTES) throw new Error("Checkpoint transfer exceeds its limit");
  const transferID = crypto.randomUUID();
  const hash = await sha256Hex(bytes);
  await bridge.request("checkpointBegin", revision, {
    transferID, baseRevision: payload.baseRevision, nextRevision: payload.nextRevision,
    totalBytes: bytes.byteLength, sha256: hash,
  });
  let sequence = 0;
  for (let offset = 0; offset < bytes.byteLength; offset += MAX_ASSET_CHUNK_BYTES) {
    await bridge.request("checkpointChunk", revision, {
      transferID, sequence, dataBase64: bytesToBase64(bytes.subarray(offset, offset + MAX_ASSET_CHUNK_BYTES)),
    });
    sequence += 1;
  }
  return bridge.request("checkpointEnd", revision, { transferID, sha256: hash });
}
