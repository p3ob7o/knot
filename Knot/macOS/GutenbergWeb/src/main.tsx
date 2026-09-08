import React, { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { createRoot } from "react-dom/client";
import {
  BlockEditorProvider, BlockList, BlockTools, WritingFlow, useBlockProps,
  __unstableEditorStyles as EditorStyles,
} from "@wordpress/block-editor";
import { createBlock, registerBlockType, setDefaultBlockName } from "@wordpress/blocks";
import { init as initCodeBlock } from "@wordpress/block-library/build-module/code/index.mjs";
import { init as initHeadingBlock } from "@wordpress/block-library/build-module/heading/index.mjs";
import { init as initListBlock } from "@wordpress/block-library/build-module/list/index.mjs";
import { init as initListItemBlock } from "@wordpress/block-library/build-module/list-item/index.mjs";
import { init as initParagraphBlock } from "@wordpress/block-library/build-module/paragraph/index.mjs";
import { init as initQuoteBlock } from "@wordpress/block-library/build-module/quote/index.mjs";
import { init as initSeparatorBlock } from "@wordpress/block-library/build-module/separator/index.mjs";
import "@wordpress/components/build-style/style.css";
import "@wordpress/block-editor/build-style/style.css";
import "@wordpress/block-library/build-style/style.css";
import "@wordpress/block-library/build-style/editor.css";
import "./styles.css";
import { checkpointRequest, resolveInitialize } from "./checkpointTransfer";
import { chunkAsset, MAX_ASSET_BYTES, sha256Hex } from "./assetTransfer";
import { BlockSpec, blockSpecForType, blocksToMarkdown, markdownToBlocks, SUPPORTED_BLOCKS } from "./codec";
import { BridgeClient, CheckpointPayload, InitializePayload, MAX_ASSET_CHUNK_BYTES } from "./protocol";

type GutenbergBlock = any;
type ImportedAsset = { id: string; url: string; alt: string; title: string; mime: string; type: "image" };
type UploadOptions = { filesList: FileList; onError?: (message: string) => void; onFileChange: (assets: ImportedAsset[]) => void };

const bootstrap = window.KnotBootstrap;
if (!bootstrap) throw new Error("Native bootstrap was not installed");
const bridge = new BridgeClient(bootstrap);

function describeError(error: unknown): string {
  return error instanceof Error ? error.message.slice(0, 512) : "Unknown editor error";
}

function reportError(code: string, error: unknown): void {
  try {
    bridge.send("editorError", bootstrap.revision, { code, category: describeError(error) });
  } catch { /* The native process may already be gone. */ }
}

window.addEventListener("error", (event) => reportError("script", event.error));
window.addEventListener("unhandledrejection", (event) => reportError("promise", event.reason));

function KnotImageEdit({ attributes }: { attributes: Record<string, string> }) {
  const blockProps = useBlockProps({ className: "knot-image-block" });
  return <figure {...blockProps}>{attributes.url
    ? <><img src={attributes.url} alt={attributes.alt || ""} title={attributes.title || ""} />{attributes.caption ? <figcaption>{attributes.caption}</figcaption> : null}</>
    : <div className="knot-image-placeholder">Image</div>}</figure>;
}

function KnotSourceEdit({ attributes, setAttributes }: { attributes: Record<string, string>; setAttributes: (value: unknown) => void }) {
  const blockProps = useBlockProps({ className: "knot-source-block" });
  return <div {...blockProps}>
    <label>Source</label>
    <textarea value={attributes.source || ""} onChange={(event) => setAttributes({ source: event.target.value })} spellCheck={false} />
  </div>;
}

function registerSupportedBlocks(): void {
  initParagraphBlock(); initHeadingBlock(); initListItemBlock(); initListBlock();
  initQuoteBlock(); initCodeBlock(); initSeparatorBlock();
  registerBlockType("core/image", {
    apiVersion: 3, title: "Image", category: "media",
    attributes: { id: { type: "string" }, url: { type: "string" }, alt: { type: "string" }, title: { type: "string" }, caption: { type: "string" } },
    supports: { html: false }, edit: KnotImageEdit, save: () => null,
  });
  registerBlockType("knot/source", {
    apiVersion: 3, title: "Source", category: "text",
    attributes: { source: { type: "string" }, reason: { type: "string" } },
    supports: { html: false }, edit: KnotSourceEdit, save: () => null,
  });
  setDefaultBlockName("core/paragraph");
}

registerSupportedBlocks();

function blocksFromSpecs(specs: BlockSpec[]): GutenbergBlock[] {
  return specs.map((spec) => {
    const attributes = { ...spec.attributes };
    if (spec.name === "core/image" && typeof attributes.id === "string") {
      attributes.url = "knot-asset://" + bootstrap.sessionID + "/" + attributes.id;
    }
    return createBlock(spec.name, attributes, spec.innerBlocks ? blocksFromSpecs(spec.innerBlocks) : undefined);
  });
}

function specsFromBlocks(blocks: GutenbergBlock[]): BlockSpec[] {
  return blocks.map((block) => ({
    name: String(block.name),
    attributes: block.attributes ?? {},
    innerBlocks: block.innerBlocks ? specsFromBlocks(block.innerBlocks) : [],
  }));
}

async function importAsset(file: File, revision: number): Promise<ImportedAsset> {
  if (!file.type.startsWith("image/") || file.size <= 0 || file.size > MAX_ASSET_BYTES) throw new Error("Use an image no larger than 25 MiB");
  const bytes = new Uint8Array(await file.arrayBuffer());
  const transferID = crypto.randomUUID();
  const digest = await sha256Hex(bytes);
  await bridge.request("assetImportBegin", revision, {
    transferID, filename: (file.name || "image").slice(0, 255), mediaType: file.type,
    totalBytes: bytes.byteLength, sha256: digest, chunkBytes: MAX_ASSET_CHUNK_BYTES,
  });
  for (const chunk of chunkAsset(bytes)) {
    await bridge.request("assetImportChunk", revision, { transferID, ...chunk });
  }
  const result = await bridge.request("assetImportEnd", revision, { transferID, sha256: digest });
  const payload = result.payload as { assetID?: string; previewURL?: string; error?: { message?: string } };
  if (!payload.assetID || !payload.previewURL) throw new Error(payload.error?.message || "Native image validation failed");
  return { id: payload.assetID, url: payload.previewURL, alt: file.name || "", title: file.name || "", mime: file.type, type: "image" };
}

async function pickNativeImages(revision: number): Promise<ImportedAsset[]> {
  const response = await bridge.request("assetPickerRequested", revision, { kind: "image", multiple: true }, 120_000);
  const payload = response.payload as {
    state?: string;
    assets?: Array<{ assetID?: string; previewURL?: string; filename?: string; mediaType?: string }>;
    error?: { message?: string };
  };
  if (payload.error) throw new Error(payload.error.message || "Native image picker failed");
  if (payload.state === "cancelled") return [];
  if (!Array.isArray(payload.assets)) throw new Error("Native image picker returned an invalid response");
  return payload.assets.map((asset) => {
    if (!asset.assetID || !asset.previewURL || !asset.mediaType) throw new Error("Native image validation failed");
    return {
      id: asset.assetID,
      url: asset.previewURL,
      alt: asset.filename || "",
      title: asset.filename || "",
      mime: asset.mediaType,
      type: "image" as const,
    };
  });
}

function EditorApp({ initial }: { initial: InitializePayload }) {
  const [blocks, setBlocks] = useState<GutenbergBlock[]>(() => {
    if (initial.blocksJSON) {
      try { return blocksFromSpecs(JSON.parse(initial.blocksJSON) as BlockSpec[]); } catch { /* Source is the recovery fallback. */ }
    }
    return blocksFromSpecs(markdownToBlocks(initial.markdown));
  });
  const [status, setStatus] = useState("Ready");
  const [acknowledgedRevision, setAcknowledgedRevision] = useState(bootstrap.revision);
  const acknowledgedRef = useRef(bootstrap.revision);
  const contentRef = useRef<HTMLElement | null>(null);
  const fileInputRef = useRef<HTMLInputElement | null>(null);
  const checkpointTimer = useRef<number | null>(null);
  const checkpointPromise = useRef<Promise<number> | null>(null);
  const assetIDs = useRef(new Set<string>(initial.assetIDs ?? []));

  const checkpoint = useCallback(async (): Promise<number> => {
    if (checkpointPromise.current) {
      await checkpointPromise.current;
      return checkpoint();
    }
    const specs = specsFromBlocks(blocks);
    const markdown = blocksToMarkdown(specs);
    const baseRevision = acknowledgedRef.current;
    const nextRevision = baseRevision + 1;
    const payload: CheckpointPayload = {
      baseRevision, nextRevision, markdown, blocksJSON: JSON.stringify(specs),
      opaqueSourcesJSON: JSON.stringify(specs.filter((item) => item.name === "knot/source")),
      selectedRange: null, assetIDs: Array.from(assetIDs.current),
    };
    setStatus("Saving locally...");
    const task = checkpointRequest(bridge, baseRevision, payload).then((response) => {
      const result = response.payload as { revision?: number; error?: { message?: string } };
      if (result.revision !== nextRevision) throw new Error(result.error?.message || "Checkpoint was not acknowledged");
      acknowledgedRef.current = nextRevision;
      setAcknowledgedRevision(nextRevision);
      setStatus("Ready");
      return nextRevision;
    }).finally(() => { checkpointPromise.current = null; });
    checkpointPromise.current = task;
    return task;
  }, [blocks]);

  useEffect(() => {
    window.KnotCheckpointForClose = checkpoint;
    const flushOnBlur = () => { checkpoint().catch((error) => setStatus(describeError(error))); };
    window.addEventListener("blur", flushOnBlur);
    return () => {
      window.removeEventListener("blur", flushOnBlur);
      delete window.KnotCheckpointForClose;
    };
  }, [checkpoint]);

  useEffect(() => {
    if (checkpointTimer.current !== null) window.clearTimeout(checkpointTimer.current);
    checkpointTimer.current = window.setTimeout(() => { checkpoint().catch((error) => { setStatus(describeError(error)); }); }, 150);
    return () => { if (checkpointTimer.current !== null) window.clearTimeout(checkpointTimer.current); };
  }, [blocks, checkpoint]);

  const save = useCallback(async () => {
    try {
      const revision = await checkpoint();
      setStatus("Saving to vault...");
      const response = await bridge.request("saveRequested", revision, { acknowledgedRevision: revision, destination: "inbox" }, 60_000);
      const payload = response.payload as { state?: string; error?: { message?: string } };
      if (payload.error) throw new Error(payload.error.message || "Save failed");
      setStatus(payload.state === "committed" ? "Saved to vault" : "Saved locally, pending vault");
    } catch (error) { setStatus(describeError(error)); }
  }, [checkpoint]);

  const addImageFiles = useCallback(async (filesList: FileList | null, onError?: (message: string) => void) => {
    const files = Array.from(filesList ?? []).filter((file) => file.type.startsWith("image/"));
    if (files.length === 0) { onError?.("Only supported image files can be imported"); return [] as ImportedAsset[]; }
    const imported: ImportedAsset[] = [];
    try {
      for (const file of files) {
        const asset = await importAsset(file, acknowledgedRef.current);
        assetIDs.current.add(asset.id);
        imported.push(asset);
      }
      return imported;
    } catch (error) { onError?.(describeError(error)); return []; }
  }, []);

  const mediaUpload = useCallback(async ({ filesList, onError, onFileChange }: UploadOptions) => {
    const imported = await addImageFiles(filesList, onError);
    if (imported.length > 0) onFileChange(imported);
  }, [addImageFiles]);

  const settings = useMemo(() => ({ allowedBlockTypes: SUPPORTED_BLOCKS.filter((name) => name !== "knot/source"), enableOpenverseMediaCategory: false, hasFixedToolbar: false, imageEditing: false, mediaUpload }), [mediaUpload]);
  const addBlock = useCallback((name: string) => {
    setBlocks((current) => [...current, ...blocksFromSpecs([blockSpecForType(name)])]);
  }, []);

  const addImagesFromNativePicker = useCallback(async () => {
    try {
      setStatus("Choose images...");
      const imported = await pickNativeImages(acknowledgedRef.current);
      for (const asset of imported) assetIDs.current.add(asset.id);
      if (imported.length > 0) {
        setBlocks((current) => [
          ...current,
          ...imported.map((asset) => createBlock("core/image", {
            id: asset.id, url: asset.url, alt: asset.alt, title: asset.title,
          })),
        ]);
      }
      setStatus("Ready");
    } catch (error) {
      setStatus(describeError(error));
    }
  }, []);

  useEffect(() => {
    const remove = bridge.onMessage((message) => {
      const payload = message.payload as { name?: string; state?: string; error?: { message?: string } };
      if (message.type === "saveResult") {
        setStatus(payload.error?.message || (payload.state === "committed" ? "Saved to vault" : "Saved locally, pending vault"));
        return;
      }
      if (message.type !== "command") return;
      if (payload.name === "save") save();
      if (payload.name === "focus") contentRef.current?.focus();
    });
    return remove;
  }, [save]);

  return <main className="knot-editor-shell">
    <div className="knot-block-toolbar" aria-label="Insert block">
      <button type="button" title="Paragraph" aria-label="Insert paragraph" onClick={() => addBlock("core/paragraph")}><b>P</b></button>
      <button type="button" title="Heading" aria-label="Insert heading" onClick={() => addBlock("core/heading")}><b>H</b></button>
      <button type="button" onClick={() => addBlock("core/list")}>List</button>
      <button type="button" onClick={() => addBlock("core/quote")}>Quote</button>
      <button type="button" onClick={() => addBlock("core/code")}>Code</button>
      <button type="button" title="Separator" onClick={() => addBlock("core/separator")}>Line</button>
      <button type="button" title="Import image" aria-label="Import image" onClick={() => { void addImagesFromNativePicker(); }}>Image</button>
      <input ref={fileInputRef} type="file" accept="image/png,image/jpeg,image/gif,image/webp,image/heic" multiple onChange={async (event) => {
        const imported = await addImageFiles(event.target.files, (message) => setStatus(message));
        event.target.value = "";
        if (imported.length) setBlocks((current) => [...current, ...imported.map((asset) => createBlock("core/image", { id: asset.id, url: asset.url, alt: asset.alt, title: asset.title }))]);
      }} />
      <span className="knot-editor-status" role="status" aria-live="polite">{status} ({acknowledgedRevision})</span>
    </div>
    <BlockEditorProvider value={blocks} onInput={setBlocks} onChange={setBlocks} settings={settings}>
      <section className="knot-editor-canvas" aria-label="Editor canvas">
        <BlockTools __unstableContentRef={contentRef} style={{ height: "100%", display: "flex" }}>
          <EditorStyles scope=":where(.editor-styles-wrapper)" transformOptions={{ ignoredSelectors: [/\.editor-styles-wrapper/gi] }} />
          <WritingFlow ref={contentRef} className="editor-styles-wrapper" tabIndex={-1}><BlockList /></WritingFlow>
        </BlockTools>
      </section>
    </BlockEditorProvider>
  </main>;
}

async function start(): Promise<void> {
  const response = await bridge.request("ready", bootstrap.revision, { buildID: __KNOT_BUILD_ID__, supportedVersions: [1] }, 5_000);
  if (response.type !== "initialize") throw new Error("Native host did not initialize the editor");
  const initial = await resolveInitialize(bridge, bootstrap.revision, response);
  if (initial.buildID !== __KNOT_BUILD_ID__) throw new Error("Editor bundle version mismatch");
  const element = document.getElementById("root");
  if (!element) throw new Error("Editor root is missing");
  createRoot(element).render(<EditorApp initial={initial} />);
}

start().catch((error) => {
  reportError("startup", error);
  const element = document.getElementById("root");
  if (element) element.textContent = "The rich editor could not start. Your source draft remains available.";
});
