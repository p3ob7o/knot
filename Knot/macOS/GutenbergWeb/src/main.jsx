import React, { useCallback, useMemo, useRef, useState } from "react";
import { createRoot } from "react-dom/client";
import {
  BlockEditorProvider,
  BlockList,
  BlockTools,
  WritingFlow,
  useBlockProps,
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
import {
  blocksToMarkdown,
} from "./serializer.js";
import {
  blockSpecForType,
  initialBlockSpecsFromText,
  SUPPORTED_BLOCKS,
} from "./blockSpecs.js";

function postToHost(message) {
  window.webkit?.messageHandlers?.knotEditor?.postMessage(message);
}

function describeError(error) {
  if (!error) {
    return "Unknown editor error";
  }
  if (error instanceof Error) {
    return error.stack || error.message;
  }
  return String(error);
}

window.addEventListener("error", (event) => {
  postToHost({
    type: "error",
    message: `Editor script error: ${describeError(event.error || event.message)}`,
  });
});

window.addEventListener("unhandledrejection", (event) => {
  postToHost({
    type: "error",
    message: `Editor promise error: ${describeError(event.reason)}`,
  });
});

function KnotImageEdit({ attributes }) {
  const blockProps = useBlockProps({
    className: "knot-image-block",
  });

  if (!attributes.url) {
    return (
      <figure {...blockProps}>
        <div className="knot-image-placeholder">Image</div>
      </figure>
    );
  }

  return (
    <figure {...blockProps}>
      <img
        src={attributes.url}
        alt={attributes.alt || ""}
        title={attributes.title || ""}
      />
    </figure>
  );
}

function registerKnotImageBlock() {
  registerBlockType("core/image", {
    apiVersion: 3,
    title: "Image",
    category: "media",
    attributes: {
      id: { type: "string" },
      url: { type: "string" },
      alt: { type: "string" },
      title: { type: "string" },
      caption: { type: "string" },
    },
    supports: {
      html: false,
    },
    edit: KnotImageEdit,
    save: () => null,
  });
}

function registerSupportedBlocks() {
  initParagraphBlock();
  initHeadingBlock();
  initListItemBlock();
  initListBlock();
  initQuoteBlock();
  initCodeBlock();
  initSeparatorBlock();
  registerKnotImageBlock();
  setDefaultBlockName("core/paragraph");
}

registerSupportedBlocks();

function readFileAsBase64(file) {
  return new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.onload = () => {
      const raw = String(reader.result || "");
      resolve(raw.includes(",") ? raw.split(",").pop() : raw);
    };
    reader.onerror = () => reject(reader.error || new Error("Could not read file."));
    reader.readAsDataURL(file);
  });
}

function blocksFromSpecs(specs) {
  return specs.map((spec) => createBlock(
    spec.name,
    spec.attributes,
    spec.innerBlocks ? blocksFromSpecs(spec.innerBlocks) : undefined
  ));
}

function EditorApp() {
  const initialText = window.KnotInitialContent || "";
  const [blocks, setBlocks] = useState(() =>
    blocksFromSpecs(initialBlockSpecsFromText(initialText))
  );
  const contentRef = useRef(null);
  const fileInputRef = useRef(null);
  const attachments = useRef(new Map());

  const readImageFiles = useCallback(async (filesList, onError) => {
    const files = Array.from(filesList || []).filter((file) =>
      file.type.startsWith("image/")
    );

    if (files.length === 0) {
      onError?.("Only image files are supported.");
      return [];
    }

    try {
      const uploaded = [];
      for (const file of files) {
        const url = URL.createObjectURL(file);
        const token = `{{knot-attachment:${globalThis.crypto.randomUUID()}}}`;
        const dataBase64 = await readFileAsBase64(file);
        attachments.current.set(url, {
          token,
          filename: file.name || "image.png",
          dataBase64,
        });
        uploaded.push({
          id: token,
          url,
          alt: file.name || "",
          title: file.name || "",
          mime: file.type,
          type: "image",
        });
      }
      return uploaded;
    } catch (error) {
      onError?.(error.message || "Could not load image.");
      return [];
    }
  }, []);

  const mediaUpload = useCallback(async ({
    filesList,
    onError,
    onFileChange,
  }) => {
    const uploaded = await readImageFiles(filesList, onError);
    if (uploaded.length > 0) {
      onFileChange(uploaded);
    }
  }, [readImageFiles]);

  const settings = useMemo(() => ({
    allowedBlockTypes: SUPPORTED_BLOCKS,
    enableOpenverseMediaCategory: false,
    hasFixedToolbar: false,
    imageEditing: false,
    mediaUpload,
  }), [mediaUpload]);

  const addBlock = useCallback((name) => {
    if (name === "core/image") {
      fileInputRef.current?.click();
      return;
    }
    setBlocks((current) => [
      ...current,
      ...blocksFromSpecs([blockSpecForType(name)]),
    ]);
  }, []);

  const addImageFiles = useCallback(async (event) => {
    const uploaded = await readImageFiles(
      event.target.files,
      (message) => {
        postToHost({
          type: "error",
          message,
        });
      }
    );
    event.target.value = "";
    if (uploaded.length === 0) {
      return;
    }
    setBlocks((current) => [
      ...current,
      ...uploaded.map((file) => createBlock("core/image", {
        id: file.id,
        url: file.url,
        alt: file.alt,
        title: file.title,
      })),
    ]);
  }, [readImageFiles]);

  const save = useCallback(() => {
    const attachmentMap = Object.fromEntries(
      Array.from(attachments.current.entries()).map(([url, value]) => [
        url,
        value.token,
      ])
    );
    const markdown = blocksToMarkdown(blocks, attachmentMap);
    const usedAttachments = Array.from(attachments.current.values()).filter(
      (attachment) => markdown.includes(attachment.token)
    );

    postToHost({
      type: "save",
      markdown,
      attachments: usedAttachments,
    });
  }, [blocks]);

  const cancel = useCallback(() => {
    postToHost({
      type: "cancel",
    });
  }, []);

  window.KnotEditor = { save, cancel };

  return (
    <main className="knot-editor-shell">
      <div className="knot-block-toolbar" aria-label="Blocks">
        <button type="button" onClick={() => addBlock("core/paragraph")}>P</button>
        <button type="button" onClick={() => addBlock("core/heading")}>H</button>
        <button type="button" onClick={() => addBlock("core/list")}>List</button>
        <button type="button" onClick={() => addBlock("core/quote")}>Quote</button>
        <button type="button" onClick={() => addBlock("core/code")}>Code</button>
        <button type="button" onClick={() => addBlock("core/separator")}>Line</button>
        <button type="button" onClick={() => addBlock("core/image")}>Image</button>
        <input
          ref={fileInputRef}
          type="file"
          accept="image/*"
          multiple
          onChange={addImageFiles}
        />
      </div>
      <BlockEditorProvider
        value={blocks}
        onInput={setBlocks}
        onChange={setBlocks}
        settings={settings}
      >
        <section className="knot-editor-canvas" aria-label="Editor canvas">
          <BlockTools
            __unstableContentRef={contentRef}
            style={{ height: "100%", display: "flex" }}
          >
            <EditorStyles
              scope=":where(.editor-styles-wrapper)"
              transformOptions={{
                ignoredSelectors: [/\.editor-styles-wrapper/gi],
              }}
            />
            <WritingFlow
              ref={contentRef}
              className="editor-styles-wrapper"
              tabIndex={-1}
            >
              <BlockList />
            </WritingFlow>
          </BlockTools>
        </section>
      </BlockEditorProvider>
    </main>
  );
}

const root = createRoot(document.getElementById("root"));
root.render(<EditorApp />);
window.setTimeout(() => {
  postToHost({
    type: "ready",
  });
}, 0);
