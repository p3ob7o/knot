// Knot — the brand mark.
// User-provided SVG (potrace traced from their original artwork).
// Inlined so `fill="currentColor"` lets it tint to the foreground color
// in dark/light themes.
//
// Original viewBox is 0 0 2560 2560 (potrace output), with a transform
// flipping Y. We render it directly so the artwork is preserved bit-exact.

function KnotMark({ size = 24, color, style = {}, ...rest }) {
  return (
    <svg
      width={size}
      height={size}
      viewBox="0 0 256 256"
      preserveAspectRatio="xMidYMid meet"
      fill={color || "currentColor"}
      style={{ display: "inline-block", verticalAlign: "middle", ...style }}
      aria-label="Knot"
      role="img"
      {...rest}
    >
      <g transform="translate(0,256) scale(0.1,-0.1)" stroke="none">
        <path d="M400 2195 c0 -225 4 -384 11 -417 27 -132 129 -273 246 -341 103 -59 159 -70 388 -74 203 -3 209 -3 185 14 -76 55 -136 112 -180 170 -111 147 -144 274 -139 543 2 96 2 241 1 323 l-2 147 -255 0 -255 0 0 -365z" />
        <path d="M1523 2268 c-257 -260 -294 -301 -324 -363 -31 -64 -34 -77 -34 -160 0 -99 9 -125 72 -202 31 -38 117 -90 179 -108 18 -5 111 86 572 552 303 307 554 561 558 566 4 4 -159 7 -362 7 l-370 0 -291 -292z" />
        <path d="M801 1224 c-132 -35 -227 -101 -302 -208 -91 -129 -93 -140 -97 -609 l-3 -407 255 0 256 0 1 53 c1 28 0 180 -1 337 -1 297 6 387 41 489 43 123 143 253 253 327 l51 34 -200 -1 c-141 0 -216 -5 -254 -15z" />
        <path d="M1378 1150 c-76 -31 -124 -68 -162 -123 -46 -70 -59 -115 -54 -202 6 -130 28 -159 381 -515 l307 -310 355 0 c299 0 355 2 355 14 0 8 -188 205 -418 438 -230 232 -482 489 -561 571 -79 81 -147 147 -150 146 -3 0 -27 -9 -53 -19z" />
      </g>
    </svg>
  );
}

window.KnotMark = KnotMark;
