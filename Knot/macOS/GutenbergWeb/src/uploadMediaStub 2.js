export function MediaUploadProvider({ children }) {
  return children;
}

export const store = {
  name: "core/upload-media",
};

export function detectClientSideMediaSupport() {
  return {
    supported: false,
    reason: "Knot handles local image attachments directly.",
  };
}

export function isHeicCanvasSupported() {
  return false;
}
