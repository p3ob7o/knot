declare module "react";
declare module "react-dom/client";
declare module "@wordpress/block-editor";
declare module "@wordpress/blocks";
declare module "@wordpress/block-library/build-module/*";

declare const __KNOT_BUILD_ID__: string;

declare namespace JSX {
  interface IntrinsicElements {
    [elementName: string]: any;
  }
}
