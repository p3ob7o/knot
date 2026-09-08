import { MAX_ASSET_CHUNK_BYTES } from "./protocol";

export const MAX_ASSET_BYTES = 25 * 1024 * 1024;
export const MAX_DRAFT_ASSET_BYTES = 100 * 1024 * 1024;
export const MAX_ASSET_COUNT = 50;

export type AssetChunk = { sequence: number; dataBase64: string };

export function bytesToBase64(bytes: Uint8Array): string {
  let value = "";
  for (let offset = 0; offset < bytes.length; offset += 0x8000) {
    value += String.fromCharCode(...bytes.subarray(offset, offset + 0x8000));
  }
  return btoa(value);
}

export function base64ToBytes(value: string): Uint8Array {
  const decoded = atob(value);
  const bytes = new Uint8Array(decoded.length);
  for (let index = 0; index < decoded.length; index += 1) bytes[index] = decoded.charCodeAt(index);
  return bytes;
}

export function chunkAsset(bytes: Uint8Array): AssetChunk[] {
  if (bytes.byteLength === 0 || bytes.byteLength > MAX_ASSET_BYTES) throw new Error("assetSize");
  const result: AssetChunk[] = [];
  for (let offset = 0, sequence = 0; offset < bytes.length; offset += MAX_ASSET_CHUNK_BYTES, sequence += 1) {
    result.push({ sequence, dataBase64: bytesToBase64(bytes.subarray(offset, offset + MAX_ASSET_CHUNK_BYTES)) });
  }
  return result;
}

export async function sha256Hex(bytes: Uint8Array): Promise<string> {
  const owned = Uint8Array.from(bytes);
  const buffer = await crypto.subtle.digest("SHA-256", owned.buffer);
  return Array.from(new Uint8Array(buffer), (byte) => byte.toString(16).padStart(2, "0")).join("");
}

export class AssetChunkAssembler {
  private chunks: Uint8Array[] = [];
  private received = 0;
  private nextSequence = 0;

  constructor(readonly declaredBytes: number) {
    if (declaredBytes <= 0 || declaredBytes > MAX_ASSET_BYTES) throw new Error("assetSize");
  }

  append(chunk: AssetChunk): void {
    if (chunk.sequence !== this.nextSequence) throw new Error("assetChunkOrder");
    const bytes = base64ToBytes(chunk.dataBase64);
    if (bytes.byteLength === 0 || bytes.byteLength > MAX_ASSET_CHUNK_BYTES) throw new Error("assetChunkSize");
    if (this.received + bytes.byteLength > this.declaredBytes) throw new Error("assetOverflow");
    this.chunks.push(bytes);
    this.received += bytes.byteLength;
    this.nextSequence += 1;
  }

  finish(): Uint8Array {
    if (this.received !== this.declaredBytes) throw new Error("assetIncomplete");
    const result = new Uint8Array(this.received);
    let offset = 0;
    for (const chunk of this.chunks) {
      result.set(chunk, offset);
      offset += chunk.byteLength;
    }
    this.chunks = [];
    return result;
  }
}
