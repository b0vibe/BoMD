import MarkdownIt from "markdown-it";
import katex from "katex";
import hljs from "highlight.js/lib/common";
import { emojiShortcodes } from "./emoji-shortcodes.js";

const markdown = new MarkdownIt({
  html: true,
  linkify: true,
  typographer: true,
  breaks: false
})
  .use(footnoteMarkdownPlugin)
  .use(katexMarkdownPlugin)
  .use(scriptMarkdownPlugin)
  .use(emojiMarkdownPlugin);

let lastRenderSignature = "";
const pendingCopyButtons = new Map();
let copyRequestID = 0;
let selectionHighlightBound = false;
let selectionHighlightFrame = 0;
let sourceLineFocusBound = false;
let sourceLineFocusFrame = 0;
let lastReportedSourceAnchor = "";
let activeRenderSequence = 0;
let viewportInteractionVersion = 0;
let viewportInteractionTrackingBound = false;
const allowedHtmlTags = new Set([
  "A", "ABBR", "ADDRESS", "ARTICLE", "ASIDE", "B", "BDI", "BDO", "BIG", "BLOCKQUOTE", "BR", "BUTTON",
  "CAPTION", "CENTER", "CITE", "CODE", "COL", "COLGROUP", "DD", "DEL", "DETAILS", "DFN", "DIV", "DL", "DT", "EM",
  "FIGCAPTION", "FIGURE", "FONT", "H1", "H2", "H3", "H4", "H5", "H6", "HR", "I", "IMG", "INS", "KBD",
  "LI", "MARK", "OL", "P", "PRE", "Q", "S", "SAMP", "SECTION", "SMALL", "SPAN", "STRONG", "SUB",
  "SUMMARY", "SUP", "TABLE", "TBODY", "TD", "TFOOT", "TH", "THEAD", "TIME", "TR", "U", "UL", "VAR",
  "MATH", "SEMANTICS", "MROW", "MI", "MN", "MO", "MS", "MTEXT", "MFRAC", "MSQRT", "MROOT", "MSUB",
  "MSUP", "MSUBSUP", "MUNDER", "MOVER", "MUNDEROVER", "MPADDED", "MPHANTOM", "ANNOTATION"
]);
const removeHtmlTagsWithContent = new Set([
  "SCRIPT", "STYLE", "IFRAME", "OBJECT", "EMBED", "LINK", "META", "BASE", "FORM", "INPUT", "TEXTAREA",
  "SELECT", "OPTION", "CANVAS", "SVG"
]);
const allowedHtmlAttributes = new Set([
  "align", "alt", "aria-hidden", "aria-label", "aria-pressed", "class", "colspan", "data-code",
  "data-copy", "data-footnote-id", "data-scroll-area", "data-toggle-wrap", "height", "href", "id",
  "lang", "name", "rel", "role", "rowspan", "scope", "src", "style", "tabindex", "target", "title", "type",
  "width", "color", "face", "size"
]);
const htmlColorNames = new Set([
  "black", "silver", "gray", "white", "maroon", "red", "purple", "fuchsia", "green", "lime",
  "olive", "yellow", "navy", "blue", "teal", "aqua", "orange", "transparent", "currentcolor"
]);
const emojiShortcodeAliases = new Map([
  ["check", "white_check_mark"],
  ["lion_face", "lion"],
  ["sun", "sunny"]
]);

const sourceLineBlockSelector = [
  "h1", "h2", "h3", "h4", "h5", "h6", "p", "li", "tr", "blockquote", "pre", "table", ".table-wrap",
  "ul", "ol", ".code-block", ".math-scroll", "hr", "figure", "img", "address", "article", "aside", "center",
  "details", "div", "section"
].map((selector) => `${selector}[data-source-line]`).join(", ");
const sourceHeadingSelector = ["h1", "h2", "h3", "h4", "h5", "h6"]
  .map((selector) => `${selector}[data-source-line]`).join(", ");

function sourceLinePlugin(md) {
  md.core.ruler.after("block", "source_line_attrs", (state) => {
    state.tokens.forEach((token) => {
      if (!token.map || token.nesting === -1 || token.type === "inline") {
        return;
      }

      token.attrSet("data-source-line", String(token.map[0] + 1));
      token.attrSet("data-source-end-line", String(Math.max(token.map[0] + 2, token.map[1] + 1)));
    });
  });
}

markdown.use(sourceLinePlugin);

markdown.renderer.rules.heading_open = (tokens, index, options, env, self) => {
  const heading = tokens[index];
  const inline = tokens[index + 1];

  if (!heading.attrGet("id")) {
    heading.attrSet("id", createHeadingSlug(inline?.content || "", env));
  }

  return self.renderToken(tokens, index, options);
};

markdown.renderer.rules.html_block = (tokens, index) => addSourceLineAttributesToHtmlBlock(
  tokens[index].content,
  tokens[index]
);

function createHeadingSlug(content, env) {
  const base = content
    .normalize("NFKC")
    .replace(/<[^>]*>/g, "")
    .replace(/[`*_~[\]()`]/g, "")
    .replace(/、/g, "")
    .trim()
    .toLowerCase()
    .replace(/[^\p{L}\p{N}\u4e00-\u9fff]+/gu, "-")
    .replace(/^-+|-+$/g, "") || "section";
  const counts = env.headingSlugCounts ||= new Map();
  const count = (counts.get(base) || 0) + 1;

  counts.set(base, count);
  return count === 1 ? base : `${base}-${count}`;
}

function emojiMarkdownPlugin(md) {
  md.core.ruler.after("inline", "emoji_shortcode", (state) => {
    replaceEmojiShortcodes(state.tokens);
  });
}

function replaceEmojiShortcodes(tokens) {
  tokens.forEach((token) => {
    if (token.type === "text") {
      token.content = token.content.replace(/:([+\-\w]+):/g, (match, name) => {
        const alias = emojiShortcodeAliases.get(name);
        return emojiShortcodes.get(name) || (alias ? emojiShortcodes.get(alias) : "") || match;
      });
    }

    if (token.children?.length) {
      replaceEmojiShortcodes(token.children);
    }
  });
}

function scriptMarkdownPlugin(md) {
  md.inline.ruler.after("escape", "subscript", subscriptInline);
  md.inline.ruler.after("subscript", "superscript", superscriptInline);
  md.renderer.rules.subscript = (tokens, index) => `<sub>${md.utils.escapeHtml(tokens[index].content)}</sub>`;
  md.renderer.rules.superscript = (tokens, index) => `<sup>${md.utils.escapeHtml(tokens[index].content)}</sup>`;
}

function subscriptInline(state, silent) {
  return scriptInline(state, silent, "~", "subscript");
}

function superscriptInline(state, silent) {
  return scriptInline(state, silent, "^", "superscript");
}

function scriptInline(state, silent, marker, tokenType) {
  if (state.src[state.pos] !== marker) {
    return false;
  }

  if (marker === "~" && (state.src[state.pos - 1] === "~" || state.src[state.pos + 1] === "~")) {
    return false;
  }

  const start = state.pos + 1;
  const end = findScriptClose(state.src, start, marker);
  if (end === -1) {
    return false;
  }

  const content = state.src.slice(start, end);
  if (!content.trim()) {
    return false;
  }

  if (!silent) {
    const token = state.push(tokenType, marker === "~" ? "sub" : "sup", 0);
    token.markup = marker;
    token.content = content;
  }

  state.pos = end + 1;
  return true;
}

function findScriptClose(source, start, marker) {
  let position = start;

  while ((position = source.indexOf(marker, position)) !== -1) {
    if (source[position - 1] === "\\") {
      position += 1;
      continue;
    }
    if (marker === "~" && source[position + 1] === "~") {
      position += 1;
      continue;
    }
    return position;
  }

  return -1;
}

function katexMarkdownPlugin(md) {
  md.inline.ruler.after("escape", "math_inline", mathInline);
  md.block.ruler.after("blockquote", "math_block", mathBlock, {
    alt: ["paragraph", "reference", "blockquote", "list"]
  });
  md.renderer.rules.math_inline = (tokens, index, options, env) => deferKatex(tokens[index].content, false, env);
  md.renderer.rules.math_block = (tokens, index, options, env) => `<div class="math-scroll"${sourceLineAttribute(tokens[index])}>${deferKatex(tokens[index].content, true, env)}</div>\n`;
}

function footnoteMarkdownPlugin(md) {
  md.inline.ruler.after("escape", "footnote_ref", footnoteRef);
  md.renderer.rules.footnote_ref = (tokens, index, options, env) => {
    const key = tokens[index].meta.key;
    const footnote = env.footnotesByKey?.get(key);

    if (!footnote) {
      return markdown.utils.escapeHtml(`[^${key}]`);
    }

    env.footnoteRefCounts ??= new Map();
    const refCount = (env.footnoteRefCounts.get(key) || 0) + 1;
    env.footnoteRefCounts.set(key, refCount);
    footnote.referenced = true;
    footnote.firstRefId ||= `fnref-${footnote.id}-${refCount}`;

    return `<span class="footnote-ref" id="fnref-${footnote.id}-${refCount}" role="doc-noteref" tabindex="0" data-footnote-id="${escapeAttribute(footnote.id)}">${markdown.utils.escapeHtml(key)}</span>`;
  };
}

function footnoteRef(state, silent) {
  if (state.env?.suppressFootnoteRefs || state.src.slice(state.pos, state.pos + 2) !== "[^") {
    return false;
  }

  const close = state.src.indexOf("]", state.pos + 2);
  if (close === -1) {
    return false;
  }

  const key = state.src.slice(state.pos + 2, close).trim();
  if (!key || !state.env?.footnotesByKey?.has(key)) {
    return false;
  }

  if (!silent) {
    const token = state.push("footnote_ref", "span", 0);
    token.meta = { key };
  }

  state.pos = close + 1;
  return true;
}

// Only parser-created math tokens enter this per-render registry. Never trust
// a document's .katex class, SVG, or MathML as permission to bypass cleanup.
function deferKatex(content, displayMode, env) {
  const { nonce, entries } = env.trustedMath;
  const key = `${nonce}-${entries.size}`;
  entries.set(key, { content, displayMode });
  return `<span data-bomd-math="${key}"></span>`;
}

function restoreKatex(root, trustedMath) {
  root.querySelectorAll("[data-bomd-math]").forEach((placeholder) => {
    const formula = trustedMath.entries.get(placeholder.getAttribute("data-bomd-math"));
    placeholder.removeAttribute("data-bomd-math");
    if (!formula) return;
    const template = root.ownerDocument.createElement("template");
    // KaTeX is the sole producer of this markup, with trust explicitly off.
    // Its SVG paths and MathML table structure must survive intact.
    template.innerHTML = renderKatex(formula.content, formula.displayMode);
    placeholder.replaceWith(template.content);
  });
}

function renderKatex(content, displayMode) {
  try {
    return katex.renderToString(content, {
      displayMode,
      throwOnError: false,
      errorColor: "#e98383",
      strict: "ignore",
      trust: false
    });
  } catch {
    return markdown.utils.escapeHtml(content);
  }
}

function mathInline(state, silent) {
  if (state.src[state.pos] !== "$") {
    return false;
  }

  const open = getDollarDelimiter(state, state.pos);
  if (!open.canOpen) {
    if (!silent) {
      state.pending += "$";
    }
    state.pos += 1;
    return true;
  }

  const start = state.pos + 1;
  let match = start;
  while ((match = state.src.indexOf("$", match)) !== -1) {
    let position = match - 1;
    while (state.src[position] === "\\") {
      position -= 1;
    }
    if ((match - position) % 2 === 1) {
      break;
    }
    match += 1;
  }

  if (match === -1) {
    if (!silent) {
      state.pending += "$";
    }
    state.pos = start;
    return true;
  }

  if (match - start === 0) {
    if (!silent) {
      state.pending += "$$";
    }
    state.pos = start + 1;
    return true;
  }

  const close = getDollarDelimiter(state, match);
  if (!close.canClose) {
    if (!silent) {
      state.pending += "$";
    }
    state.pos = start;
    return true;
  }

  if (!silent) {
    const token = state.push("math_inline", "math", 0);
    token.markup = "$";
    token.content = state.src.slice(start, match);
  }

  state.pos = match + 1;
  return true;
}

function mathBlock(state, startLine, endLine, silent) {
  let position = state.bMarks[startLine] + state.tShift[startLine];
  let max = state.eMarks[startLine];

  if (position + 2 > max || state.src.slice(position, position + 2) !== "$$") {
    return false;
  }

  position += 2;
  let firstLine = state.src.slice(position, max);
  let lastLine = "";
  let nextLine = startLine;
  let found = false;

  if (silent) {
    return true;
  }

  if (firstLine.trim().endsWith("$$")) {
    firstLine = firstLine.trim().slice(0, -2);
    found = true;
  }

  while (!found) {
    nextLine += 1;
    if (nextLine >= endLine) {
      break;
    }

    position = state.bMarks[nextLine] + state.tShift[nextLine];
    max = state.eMarks[nextLine];

    if (position < max && state.tShift[nextLine] < state.blkIndent) {
      break;
    }

    const currentLine = state.src.slice(position, max);
    if (currentLine.trim().endsWith("$$")) {
      const lastPosition = currentLine.lastIndexOf("$$");
      lastLine = currentLine.slice(0, lastPosition);
      found = true;
    }
  }

  state.line = nextLine + 1;

  const token = state.push("math_block", "math", 0);
  token.block = true;
  token.content = [
    firstLine && firstLine.trim() ? `${firstLine}\n` : "",
    state.getLines(startLine + 1, nextLine, state.tShift[startLine], true),
    lastLine && lastLine.trim() ? lastLine : ""
  ].join("");
  token.map = [startLine, state.line];
  token.markup = "$$";
  return true;
}

function getDollarDelimiter(state, position) {
  const previousChar = position > 0 ? state.src.charCodeAt(position - 1) : -1;
  const nextChar = position + 1 <= state.posMax ? state.src.charCodeAt(position + 1) : -1;
  const nextIsDigit = nextChar >= 0x30 && nextChar <= 0x39;
  const previousIsSpace = previousChar === 0x20 || previousChar === 0x09;
  const nextIsSpace = nextChar === 0x20 || nextChar === 0x09;

  return {
    canOpen: !nextIsSpace,
    canClose: !previousIsSpace && !nextIsDigit
  };
}

markdown.renderer.rules.table_open = (tokens, index) => `<div class="table-wrap"${sourceLineAttribute(tokens[index])}><table>`;
markdown.renderer.rules.table_close = () => "</table></div>";
markdown.renderer.rules.fence = (tokens, index) => {
  const token = tokens[index];
  const language = token.info.trim().split(/\s+/)[0] || "";
  const normalizedLanguage = language && hljs.getLanguage(language) ? language : "";
  const highlighted = normalizedLanguage
    ? hljs.highlight(token.content, { language: normalizedLanguage, ignoreIllegals: true }).value
    : markdown.utils.escapeHtml(token.content);
  const languageLabel = normalizedLanguage || "text";

  return [
    `<div class="code-block" data-code="${encodeURIComponent(token.content)}"${sourceLineAttribute(token)}>`,
    `<div class="code-titlebar"><span class="code-language">${markdown.utils.escapeHtml(languageLabel)}</span><div class="code-actions"><span class="code-action-cluster wrap-control"><button type="button" data-toggle-wrap aria-pressed="true" aria-label="自动换行：开启" data-tooltip="自动换行：开启"><span class="code-action-icon wrap-icon" aria-hidden="true"></span></button></span><span class="code-action-cluster copy-control"><button type="button" data-copy aria-label="复制代码" data-tooltip="复制代码"><span class="code-action-icon copy-icon" aria-hidden="true"></span><span class="copy-check" aria-hidden="true"></span></button></span></div></div>`,
    `<div class="code-scroll"><pre data-scroll-area><code class="hljs language-${markdown.utils.escapeHtml(language)}">${highlighted}</code></pre><div class="code-scrollbar" aria-hidden="true"><div class="code-scrollbar-thumb"></div></div></div>`,
    `</div>`
  ].join("");
};

function rewriteImageSources(root, basePath) {
  root.querySelectorAll("img").forEach((image) => {
    const rawSource = image.getAttribute("src") || "";

    if (!rawSource || /^[a-zA-Z][a-zA-Z\d+.-]*:/.test(rawSource) || rawSource.startsWith("/")) {
      return;
    }

    const joined = `${basePath.replace(/\/$/, "")}/${rawSource}`;
    image.src = `bomd-local://${encodeURIComponent(normalizePath(joined))}`;
  });
}

function normalizeDataImageMarkdown(source) {
  return source.replace(/!\[([^\]]*)\]\((data:image\/[^)\s]+)\)/gi, (match, alt, rawSource) => {
    const normalizedSvgSource = normalizeSvgDataImageSource(rawSource);
    if (normalizedSvgSource) {
      return `<img class="embedded-image" src="${escapeAttribute(normalizedSvgSource)}" alt="${escapeAttribute(alt)}">`;
    }

    return isSupportedBitmapDataImage(rawSource) ? match : "";
  });
}

function normalizeSvgDataImageSource(rawSource) {
  const match = rawSource.match(/^data:image\/svg\+xml(?:;charset=[^;,]+)?(;base64)?,([\s\S]*)$/i);
  if (!match) {
    return "";
  }

  const svg = decodeDataImagePayload(match[2], Boolean(match[1]));
  if (!svg || !hasRenderableSvgContent(svg)) {
    return "";
  }

  return `data:image/svg+xml;base64,${encodeBase64Utf8(svg)}`;
}

function isSupportedBitmapDataImage(rawSource) {
  return /^data:image\/(?:png|jpe?g|gif|webp);base64,[a-z0-9+/]+={0,2}$/i.test(rawSource);
}

function decodeDataImagePayload(payload, isBase64) {
  try {
    if (!isBase64) {
      return decodeURIComponent(payload);
    }

    const binary = atob(payload);
    const bytes = Uint8Array.from(binary, (character) => character.charCodeAt(0));
    return new TextDecoder().decode(bytes);
  } catch {
    return "";
  }
}

function hasRenderableSvgContent(svg) {
  return /<(?:path|rect|circle|ellipse|line|polyline|polygon|image|text|use)\b/i.test(svg);
}

function encodeBase64Utf8(value) {
  const bytes = new TextEncoder().encode(value);
  let binary = "";

  bytes.forEach((byte) => {
    binary += String.fromCharCode(byte);
  });

  return btoa(binary);
}

function bindImageFallbacks(root) {
  root.querySelectorAll("img").forEach((image) => {
    image.addEventListener("error", () => {
      const fallback = document.createElement("span");
      const alt = image.getAttribute("alt")?.trim();

      fallback.className = "image-load-error";
      fallback.textContent = alt ? `图片无法加载：${alt}` : "图片无法加载";
      fallback.title = "图片资源不可用";
      image.replaceWith(fallback);
    }, { once: true });
  });
}

function normalizePath(path) {
  const parts = [];
  path.split("/").forEach((part) => {
    if (!part || part === ".") {
      return;
    }
    if (part === "..") {
      parts.pop();
      return;
    }
    parts.push(part);
  });
  return `/${parts.join("/")}`;
}

function bindCodeActions(root) {
  root.querySelectorAll(".code-block").forEach((block) => {
    const scrollArea = block.querySelector("[data-scroll-area]");
    const scrollThumb = block.querySelector(".code-scrollbar-thumb");
    let scrollTimer;

    const updateScrollbar = () => {
      if (!scrollArea || !scrollThumb) {
        return;
      }

      const maxScroll = scrollArea.scrollWidth - scrollArea.clientWidth;
      const trackWidth = scrollThumb.parentElement.clientWidth;

      if (maxScroll <= 0 || trackWidth <= 0) {
        scrollThumb.style.width = "0px";
        scrollThumb.style.transform = "translateX(0)";
        return;
      }

      const thumbWidth = Math.max(48, (scrollArea.clientWidth / scrollArea.scrollWidth) * trackWidth);
      const travel = trackWidth - thumbWidth;
      const progress = scrollArea.scrollLeft / maxScroll;

      scrollThumb.style.width = `${thumbWidth}px`;
      scrollThumb.style.transform = `translateX(${progress * travel}px)`;
    };

    const showScrollbarBriefly = () => {
      updateScrollbar();
      block.classList.add("is-scrolling");
      window.clearTimeout(scrollTimer);
      scrollTimer = window.setTimeout(() => {
        block.classList.remove("is-scrolling");
      }, 900);
    };

    scrollArea?.addEventListener("scroll", showScrollbarBriefly);
    window.requestAnimationFrame(updateScrollbar);
  });

  root.querySelectorAll("[data-toggle-wrap]").forEach((button) => {
    button.addEventListener("click", () => {
      const block = button.closest(".code-block");
      const scrollArea = block?.querySelector("[data-scroll-area]");
      const noWrap = block.classList.toggle("no-wrap");
      const wrapEnabled = !noWrap;

      button.setAttribute("aria-pressed", String(wrapEnabled));
      button.setAttribute("aria-label", `自动换行：${wrapEnabled ? "开启" : "关闭"}`);
      button.dataset.tooltip = `自动换行：${wrapEnabled ? "开启" : "关闭"}`;

      if (scrollArea) {
        scrollArea.scrollLeft = 0;
        window.requestAnimationFrame(() => scrollArea.dispatchEvent(new Event("scroll")));
      }
    });
  });

  root.querySelectorAll("[data-copy]").forEach((button) => {
    button.addEventListener("click", () => {
      const block = button.closest(".code-block");
      const encodedCode = block?.dataset.code || "";
      const code = decodeURIComponent(encodedCode);
      const requestID = `copy-${copyRequestID += 1}`;

      pendingCopyButtons.set(requestID, {
        button,
        cluster: button.closest(".copy-control")
      });

      postEvent("code_copy_request", {
        requestID,
        code,
        length: code.length
      });
    });
  });
}

let documentScrollbarBound = false;
let documentScrollbarDragging = false;
let documentScrollbarPointerID = null;
let anchorLinksBound = false;

function bindAnchorLinks(root) {
  if (anchorLinksBound) {
    return;
  }

  root.addEventListener("click", (event) => {
    const link = event.target.closest?.('a[href^="#"]');
    if (!link) {
      return;
    }

    const rawFragment = (link.getAttribute("href") || "").slice(1);
    let targetID;
    try {
      targetID = decodeURIComponent(rawFragment);
    } catch {
      return;
    }

    const scrollArea = document.querySelector("#document-scroll-area");
    if (!scrollArea) {
      return;
    }

    if (!targetID) {
      event.preventDefault();
      scrollArea.scrollTo({ top: 0, behavior: "smooth" });
      return;
    }

    const target = document.getElementById(targetID)
      || Array.from(root.querySelectorAll("a[name]")).find((anchor) => anchor.getAttribute("name") === targetID);
    if (!target) {
      return;
    }

    event.preventDefault();
    scrollToAnchorTarget(target, scrollArea);
  });

  anchorLinksBound = true;
}

function scrollToAnchorTarget(target, scrollArea) {
  const targetRect = target.getBoundingClientRect();
  const scrollAreaRect = scrollArea.getBoundingClientRect();
  const maximum = Math.max(0, scrollArea.scrollHeight - scrollArea.clientHeight);
  const top = Math.min(
    maximum,
    Math.max(0, scrollArea.scrollTop + targetRect.top - scrollAreaRect.top - 12)
  );

  scrollArea.scrollTo({ top, behavior: "smooth" });
}

function bindDocumentScrollbar(root) {
  const scrollArea = document.querySelector("#document-scroll-area");
  const track = document.querySelector("#document-scrollbar");
  const thumb = document.querySelector("#document-scrollbar-thumb");
  if (!scrollArea || !track || !thumb) {
    return;
  }

  const metrics = () => {
    const documentHeight = scrollArea.scrollHeight;
    const maxScroll = Math.max(0, documentHeight - scrollArea.clientHeight);
    const trackHeight = track.clientHeight;
    const thumbHeight = maxScroll > 0 && trackHeight > 0
      ? Math.max(28, (scrollArea.clientHeight / documentHeight) * trackHeight)
      : 0;
    return { maxScroll, trackHeight, thumbHeight };
  };

  const update = () => {
    const { maxScroll, trackHeight, thumbHeight } = metrics();
    if (maxScroll <= 0 || trackHeight <= 0) {
      track.hidden = true;
      return;
    }

    track.hidden = false;
    const travel = Math.max(0, trackHeight - thumbHeight);
    const progress = Math.min(1, Math.max(0, scrollArea.scrollTop / maxScroll));
    thumb.style.height = `${thumbHeight}px`;
    thumb.style.transform = `translateY(${progress * travel}px)`;
  };

  const scrollFromPointer = (clientY, thumbOffset) => {
    const { maxScroll, trackHeight, thumbHeight } = metrics();
    if (maxScroll <= 0 || trackHeight <= thumbHeight) {
      return;
    }

    const bounds = track.getBoundingClientRect();
    const travel = trackHeight - thumbHeight;
    const progress = Math.min(1, Math.max(0, (clientY - bounds.top - thumbOffset) / travel));
    scrollArea.scrollTo(0, progress * maxScroll);
    update();
  };

  if (!documentScrollbarBound) {
    scrollArea.addEventListener("scroll", () => {
      update();
      window.dispatchEvent(new Event("scroll"));
    }, { passive: true });
    window.addEventListener("resize", update);

    track.addEventListener("pointerdown", (event) => {
      const thumbBounds = thumb.getBoundingClientRect();
      const thumbOffset = event.target === thumb
        ? event.clientY - thumbBounds.top
        : thumbBounds.height / 2;

      documentScrollbarDragging = true;
      documentScrollbarPointerID = event.pointerId;
      track.setPointerCapture(event.pointerId);
      scrollFromPointer(event.clientY, thumbOffset);
      track.dataset.dragOffset = String(thumbOffset);
      event.preventDefault();
    });

    track.addEventListener("pointermove", (event) => {
      if (!documentScrollbarDragging || event.pointerId !== documentScrollbarPointerID) {
        return;
      }
      scrollFromPointer(event.clientY, Number(track.dataset.dragOffset || "0"));
      event.preventDefault();
    });

    const finishDrag = (event) => {
      if (!documentScrollbarDragging || event.pointerId !== documentScrollbarPointerID) {
        return;
      }
      if (track.hasPointerCapture(event.pointerId)) {
        track.releasePointerCapture(event.pointerId);
      }
      documentScrollbarDragging = false;
      documentScrollbarPointerID = null;
    };

    track.addEventListener("pointerup", finishDrag);
    track.addEventListener("pointercancel", finishDrag);
    documentScrollbarBound = true;
  }

  root.querySelectorAll("img").forEach((image) => {
    image.addEventListener("load", update, { once: true });
    image.addEventListener("error", update, { once: true });
  });
  window.requestAnimationFrame(update);
}

function enhanceTaskLists(root) {
  root.querySelectorAll("li").forEach((item) => {
    const marker = findTaskMarker(item);
    if (!marker) {
      return;
    }

    marker.node.nodeValue = marker.node.nodeValue.replace(/^\s*\[[ xX]\]\s+/, "");

    const checkbox = document.createElement("span");
    checkbox.className = `task-checkbox ${marker.checked ? "is-checked" : "is-unchecked"}`;
    checkbox.setAttribute("aria-hidden", "true");

    item.classList.add("task-list-item");
    if (marker.checked) {
      item.classList.add("is-checked");
    }
    item.parentElement?.classList.add("task-list");
    item.insertBefore(checkbox, item.firstChild);
  });
}

function enhanceTableLayout(root) {
  root.querySelectorAll("table").forEach((table) => {
    const wrapper = table.closest(".table-wrap");
    if (wrapper) {
      wrapper.tabIndex = 0;
      wrapper.setAttribute("role", "region");
      wrapper.setAttribute("aria-label", "表格，可横向滚动");
    }
    const rows = Array.from(table.rows);
    const columnCount = Math.max(0, ...rows.map((row) => row.cells.length));
    const hasSimpleColumns = columnCount > 0 && rows.every((row) => (
      row.cells.length === columnCount
      && Array.from(row.cells).every((cell) => cell.colSpan === 1)
    ));

    table.classList.toggle("has-smart-columns", hasSimpleColumns);
    if (!hasSimpleColumns) {
      table.dataset.columnLayout = `unsupported:${rows.map((row) => row.cells.length).join(",")}`;
      return;
    }

    const columnLayouts = classifyTableColumns(rows.map((row) => (
      Array.from(row.cells, (cell) => cell.textContent.trim())
    )));
    table.dataset.columnLayout = columnLayouts.map((layout) => layout.type).join(",");
    // Percentages alone turn minimum widths into weights and collapse wide
    // tables. Keep their real minimum width; the wrapper owns the overflow.
    const minimumWidth = columnLayouts.reduce((sum, layout) => sum + layout.minWidthRem, 0);
    table.style.minWidth = `${minimumWidth}rem`;

    rows.forEach((row) => {
      Array.from(row.cells).forEach((cell, columnIndex) => {
        const layout = columnLayouts[columnIndex];
        cell.classList.add(`table-column-${layout.type}`);
        cell.style.width = `${layout.widthPercent}%`;
      });
    });
  });
}

function classifyTableColumns(rows) {
  const columnCount = Math.max(0, ...rows.map((row) => row.length));
  const profiles = Array.from({ length: columnCount }, (_, columnIndex) => {
    const values = rows
      .map((row) => String(row[columnIndex] || "").replace(/\s+/g, " ").trim())
      .filter(Boolean);
    const bodyValues = values.slice(1);
    const measuredValues = values.map(measureTableTextWidth);
    const maxWidth = Math.max(0, ...measuredValues);
    const averageWidth = measuredValues.length
      ? measuredValues.reduce((total, width) => total + width, 0) / measuredValues.length
      : 0;
    const isKeyColumn = columnIndex === 0
      && bodyValues.length > 0
      && bodyValues.every((value) => value.length <= 40 && isCompactTableToken(value))
      && bodyValues.some((value) => /[\d_.:/-]/u.test(value));
    const isCompactColumn = !isKeyColumn
      && maxWidth <= 8
      && averageWidth <= 6.5;

    return {
      type: isKeyColumn ? "key" : isCompactColumn ? "compact" : "text",
      maxWidth,
      averageWidth
    };
  });
  const flexibleColumn = profiles
    .map((profile, index) => ({ profile, index }))
    .filter(({ profile }) => profile.type === "text")
    .sort((first, second) => (
      (second.profile.maxWidth + second.profile.averageWidth)
      - (first.profile.maxWidth + first.profile.averageWidth)
    ))[0];

  if (flexibleColumn) {
    profiles[flexibleColumn.index].type = "flex";
  }

  const layouts = profiles.map((profile) => ({
    type: profile.type,
    minWidthRem: tableColumnMinimumWidth(profile)
  }));
  const totalWidth = layouts.reduce((total, layout) => total + layout.minWidthRem, 0) || 1;
  let assignedPercent = 0;

  return layouts.map((layout, index) => {
    const widthPercent = index === layouts.length - 1
      ? Number((100 - assignedPercent).toFixed(2))
      : Number((layout.minWidthRem / totalWidth * 100).toFixed(2));
    assignedPercent += widthPercent;
    return { ...layout, widthPercent };
  });
}

function isCompactTableToken(value) {
  return !/\s/u.test(value) && /^[\p{L}\p{N}_.:/#@+\-]+$/u.test(value);
}

function measureTableTextWidth(value) {
  return Array.from(value).reduce((width, character) => {
    if (/\s/u.test(character)) {
      return width + 0.35;
    }
    if (/^[\x00-\x7F]$/u.test(character)) {
      return width + 0.62;
    }
    return width + 1;
  }, 0);
}

function tableColumnMinimumWidth(profile) {
  const clamp = (minimum, value, maximum) => Math.min(Math.max(value, minimum), maximum);
  const width = profile.type === "key"
    ? clamp(10, profile.maxWidth + 4, 15)
    : profile.type === "compact"
      ? clamp(4, profile.maxWidth + 2, 10)
      : profile.type === "flex"
        ? clamp(13, profile.maxWidth * 0.08 + 3, 16)
        : clamp(10, profile.maxWidth * 0.3 + 2, 14);

  return Number(width.toFixed(2));
}

function findTaskMarker(item) {
  const textNode = findFirstListText(item);
  const match = textNode?.nodeValue.match(/^\s*\[([ xX])\]\s+/);

  if (!match) {
    return null;
  }

  return {
    node: textNode,
    checked: match[1].toLowerCase() === "x"
  };
}

function findFirstListText(node) {
  for (const child of node.childNodes) {
    if (child.nodeType === Node.TEXT_NODE) {
      if (child.nodeValue.trim()) {
        return child;
      }
      continue;
    }

    if (child.nodeType !== Node.ELEMENT_NODE) {
      continue;
    }

    if (["CODE", "PRE", "KBD", "SAMP"].includes(child.tagName)) {
      continue;
    }

    const textNode = findFirstListText(child);
    if (textNode) {
      return textNode;
    }
  }

  return null;
}

function bindSelectionHighlight() {
  if (selectionHighlightBound) {
    return;
  }
  selectionHighlightBound = true;

  document.addEventListener("selectionchange", scheduleSelectionHighlightUpdate);
  window.addEventListener("scroll", scheduleSelectionHighlightUpdate, { passive: true });
  window.addEventListener("resize", scheduleSelectionHighlightUpdate);
}

function scheduleSelectionHighlightUpdate() {
  if (selectionHighlightFrame) {
    return;
  }

  selectionHighlightFrame = window.requestAnimationFrame(() => {
    selectionHighlightFrame = 0;
    updateSelectionHighlight();
  });
}

function updateSelectionHighlight() {
  const root = document.querySelector("#document");
  const overlay = ensureSelectionHighlightOverlay();
  const selection = window.getSelection();

  overlay.replaceChildren();
  document.body.classList.remove("has-selection-overlay");
  clearSelectionCoveredInlineCode(root);
  if (!root || !selection || selection.isCollapsed || selection.rangeCount === 0) {
    return;
  }

  try {
    const textRects = [];
    const mathRects = [];
    const selectionRanges = [];
    for (let index = 0; index < selection.rangeCount; index += 1) {
      const range = selection.getRangeAt(index);
      if (!rangeIntersectsNode(range, root)) {
        continue;
      }
      selectionRanges.push(range);
      textRects.push(...getSelectedTextRects(range, root));
      mathRects.push(...getSelectedMathRects(range, root));
    }

    const mergedTextRects = mergeSelectionRects(textRects);
    const uniqueMathRects = mergeMathSelectionRects(mathRects);
    if (!mergedTextRects.length && !uniqueMathRects.length) {
      return;
    }

    mergedTextRects.forEach((rect) => {
      const highlight = document.createElement("span");
      highlight.className = "selection-line";
      highlight.style.left = `${rect.left}px`;
      highlight.style.top = `${rect.top}px`;
      highlight.style.width = `${rect.right - rect.left}px`;
      highlight.style.height = `${rect.bottom - rect.top}px`;
      overlay.appendChild(highlight);
    });
    uniqueMathRects.forEach((rect) => {
      const highlight = document.createElement("span");
      highlight.className = "selection-line selection-math";
      highlight.style.left = `${rect.left - 3}px`;
      highlight.style.top = `${rect.top - 2}px`;
      highlight.style.width = `${rect.right - rect.left + 6}px`;
      highlight.style.height = `${rect.bottom - rect.top + 4}px`;
      overlay.appendChild(highlight);
    });
    markSelectionCoveredInlineCode(root, selectionRanges);
    document.body.classList.add("has-selection-overlay");
  } catch {
    // Keep the native selection visible if a browser-specific range edge case
    // prevents custom rectangle extraction.
    overlay.replaceChildren();
  }
}

function ensureSelectionHighlightOverlay() {
  let overlay = document.querySelector("#selection-highlight");
  if (!overlay) {
    overlay = document.createElement("div");
    overlay.id = "selection-highlight";
    overlay.setAttribute("aria-hidden", "true");
    document.body.prepend(overlay);
  }
  return overlay;
}

function getSelectedTextRects(selectionRange, root) {
  const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
  const rects = [];
  let textNode;

  while ((textNode = walker.nextNode())) {
    if (!textNode.nodeValue?.trim() || textNode.parentElement?.closest("pre, .code-block, .katex")) {
      continue;
    }

    if (!rangeIntersectsNode(selectionRange, textNode)) {
      continue;
    }

    const start = selectionRange.startContainer === textNode ? selectionRange.startOffset : 0;
    const end = selectionRange.endContainer === textNode ? selectionRange.endOffset : textNode.length;
    if (end <= start) {
      continue;
    }

    const selectedTextRange = document.createRange();
    selectedTextRange.setStart(textNode, start);
    selectedTextRange.setEnd(textNode, end);
    Array.from(selectedTextRange.getClientRects()).forEach((rect) => {
      if (rect.width > 0 && rect.height > 0) {
        rects.push({ left: rect.left, top: rect.top, right: rect.right, bottom: rect.bottom });
      }
    });
  }

  return rects;
}

function getSelectedMathRects(selectionRange, root) {
  return Array.from(root.querySelectorAll(".katex"))
    .filter((formula) => rangeIntersectsNode(selectionRange, formula))
    .map((formula) => formula.getBoundingClientRect())
    .filter((rect) => rect.width > 0 && rect.height > 0)
    .map((rect) => ({ left: rect.left, top: rect.top, right: rect.right, bottom: rect.bottom }));
}

function clearSelectionCoveredInlineCode(root) {
  root?.querySelectorAll("code.selection-covered-inline-code").forEach((code) => {
    code.classList.remove("selection-covered-inline-code");
  });
}

function markSelectionCoveredInlineCode(root, ranges) {
  root.querySelectorAll("code:not(.hljs)").forEach((code) => {
    if (ranges.some((range) => rangeIntersectsNode(range, code))) {
      code.classList.add("selection-covered-inline-code");
    }
  });
}

function mergeSelectionRects(rects) {
  const maxInlineGap = 14;
  return rects
    .sort((first, second) => first.top - second.top || first.left - second.left)
    .reduce((merged, rect) => {
      const previous = merged[merged.length - 1];
      const sharesLine = previous && Math.abs(previous.top - rect.top) < 2 && Math.abs(previous.bottom - rect.bottom) < 2;
      if (sharesLine && rect.left - previous.right <= maxInlineGap) {
        previous.right = Math.max(previous.right, rect.right);
        previous.top = Math.min(previous.top, rect.top);
        previous.bottom = Math.max(previous.bottom, rect.bottom);
      } else {
        merged.push({ ...rect });
      }
      return merged;
    }, []);
}

function mergeMathSelectionRects(rects) {
  const seen = new Set();

  return rects.filter((rect) => {
    const key = `${rect.left}:${rect.top}:${rect.right}:${rect.bottom}`;
    if (seen.has(key)) {
      return false;
    }
    seen.add(key);
    return true;
  });
}

function rangeIntersectsNode(range, node) {
  try {
    return range.intersectsNode(node);
  } catch {
    return node.contains(range.commonAncestorContainer);
  }
}

function extractFootnotes(source) {
  const lines = source.split(/\r?\n/);
  const bodyLines = [...lines];
  const footnotes = [];
  const footnotesByKey = new Map();

  for (let index = 0; index < lines.length; index += 1) {
    const match = lines[index].match(/^ {0,3}\[\^([^\]]+)\]:\s*(.*)$/);

    if (!match) {
      continue;
    }

    const key = match[1].trim();
    const contentLines = [match[2]];
    bodyLines[index] = "";

    while (index + 1 < lines.length && /^(?: {4}|\t)/.test(lines[index + 1])) {
      index += 1;
      contentLines.push(lines[index].replace(/^(?: {4}|\t)/, ""));
      bodyLines[index] = "";
    }

    if (!key || footnotesByKey.has(key)) {
      continue;
    }

    const footnote = {
      id: `fn-${footnotes.length + 1}`,
      key,
      content: contentLines.join("\n").trim(),
      referenced: false,
      firstRefId: ""
    };

    footnotes.push(footnote);
    footnotesByKey.set(key, footnote);
  }

  return {
    source: bodyLines.join("\n"),
    footnotes,
    footnotesByKey,
    footnoteRefCounts: new Map()
  };
}

function appendFootnotes(root, footnoteData) {
  if (!footnoteData.footnotes.length) {
    return;
  }

  // Use the template's inert owner document for footnote HTML as well.
  const ownerDocument = root.ownerDocument;
  const section = ownerDocument.createElement("section");
  section.className = "footnotes";
  section.setAttribute("role", "doc-endnotes");

  footnoteData.footnotes.forEach((footnote) => {
    const item = ownerDocument.createElement("p");
    item.className = "footnote-item";
    item.id = footnote.id;
    item.dataset.footnoteId = footnote.id;

    const content = markdown.renderInline(footnote.content, {
      ...footnoteData,
      suppressFootnoteRefs: true
    });
    const backref = footnote.firstRefId
      ? `<a class="footnote-backref" href="#${escapeAttribute(footnote.firstRefId)}" aria-label="返回脚注引用">↩</a>`
      : "";

    item.innerHTML = `<span class="footnote-key">[^ ${markdown.utils.escapeHtml(footnote.key)} ]:</span> <span class="footnote-content">${content}</span> ${backref}`;
    section.appendChild(item);
  });

  root.appendChild(section);
}

function bindFootnotePopovers(root) {
  const refs = root.querySelectorAll(".footnote-ref");
  if (!refs.length) {
    hideFootnotePopover();
    return;
  }

  refs.forEach((ref) => {
    ref.addEventListener("mouseenter", () => showFootnotePopover(ref, root));
    ref.addEventListener("focus", () => showFootnotePopover(ref, root));
    ref.addEventListener("mouseleave", hideFootnotePopover);
    ref.addEventListener("blur", hideFootnotePopover);
  });
}

function showFootnotePopover(ref, root) {
  const footnote = root.querySelector(`#${ref.dataset.footnoteId}`);
  const content = footnote?.querySelector(".footnote-content");

  if (!content) {
    return;
  }

  const popover = ensureFootnotePopover();
  popover.replaceChildren(...Array.from(content.childNodes, (node) => node.cloneNode(true)));
  popover.classList.add("is-visible");
  popover.style.left = "0px";
  popover.style.top = "0px";

  const refRect = ref.getBoundingClientRect();
  const popoverRect = popover.getBoundingClientRect();
  const margin = 10;
  const left = Math.min(
    Math.max(margin, refRect.left + (refRect.width / 2) - (popoverRect.width / 2)),
    window.innerWidth - popoverRect.width - margin
  );
  const belowTop = refRect.bottom + 8;
  const aboveTop = refRect.top - popoverRect.height - 8;
  const top = belowTop + popoverRect.height + margin <= window.innerHeight
    ? belowTop
    : Math.max(margin, aboveTop);

  popover.style.left = `${left}px`;
  popover.style.top = `${top}px`;
}

function ensureFootnotePopover() {
  let popover = document.querySelector("#footnote-popover");

  if (!popover) {
    popover = document.createElement("div");
    popover.id = "footnote-popover";
    popover.className = "footnote-popover";
    popover.setAttribute("role", "tooltip");
    document.body.appendChild(popover);
  }

  return popover;
}

function hideFootnotePopover() {
  document.querySelector("#footnote-popover")?.classList.remove("is-visible");
}

function escapeAttribute(value) {
  return markdown.utils.escapeHtml(String(value)).replace(/"/g, "&quot;");
}

function sourceLineAttribute(token) {
  const sourceLine = token.attrGet?.("data-source-line");
  const sourceEndLine = token.attrGet?.("data-source-end-line");
  if (!sourceLine) {
    return "";
  }
  return ` data-source-line="${escapeAttribute(sourceLine)}" data-source-end-line="${escapeAttribute(sourceEndLine || sourceLine)}"`;
}

function addSourceLineAttributesToHtmlBlock(content, token) {
  const attributes = sourceLineAttribute(token);
  if (!attributes) {
    return content;
  }

  return content.replace(/^(\s*<[a-z][\w:-]*)(?=[\s/>])/i, `$1${attributes}`);
}

function sanitizeRenderedHtml(root) {
  Array.from(root.querySelectorAll("*")).reverse().forEach((element) => {
    const tagName = element.tagName.toUpperCase();
    if (removeHtmlTagsWithContent.has(tagName) || tagName === "TEMPLATE"
      || !["http://www.w3.org/1999/xhtml", "http://www.w3.org/1998/Math/MathML"].includes(element.namespaceURI)) {
      element.remove();
      return;
    }

    if (!allowedHtmlTags.has(tagName)) {
      element.replaceWith(...Array.from(element.childNodes));
      return;
    }

    sanitizeHtmlAttributes(element);
    applyLegacyHtmlAttributes(element);
  });
}

function sanitizeHtmlAttributes(element) {
  Array.from(element.attributes).forEach((attribute) => {
    const name = attribute.name.toLowerCase();
    const value = attribute.value;

    // Preserve ordered-list semantics without widening the general attribute
    // allowlist. Other elements and non-integer values still get stripped.
    if (name === "start" && element.tagName === "OL" && /^-?\d{1,9}$/.test(value.trim())) {
      element.setAttribute("start", String(Number(value)));
      return;
    }

    if (name.startsWith("on") || (!allowedHtmlAttributes.has(name) && !name.startsWith("data-"))) {
      element.removeAttribute(attribute.name);
      return;
    }

    if ((name === "href" || name === "src") && !isSafeHtmlUrl(value, name === "src")) {
      element.removeAttribute(attribute.name);
      return;
    }

    if (name === "style") {
      const safeStyle = sanitizeInlineStyle(value);
      if (safeStyle) {
        element.setAttribute("style", safeStyle);
      } else {
        element.removeAttribute("style");
      }
    }
  });

  if (element.tagName === "A" && element.getAttribute("target") === "_blank") {
    element.setAttribute("rel", "noopener noreferrer");
  }
}

function applyLegacyHtmlAttributes(element) {
  const align = element.getAttribute("align")?.trim().toLowerCase();
  if (["left", "center", "right", "justify"].includes(align)) {
    element.style.textAlign = align;
  }

  if (element.tagName !== "FONT") {
    return;
  }

  const color = sanitizeHtmlColor(element.getAttribute("color") || "");
  const size = sanitizeFontSize(element.getAttribute("size") || "");
  const face = sanitizeFontFace(element.getAttribute("face") || "");

  if (color) {
    element.style.color = color;
  }
  if (size) {
    element.style.fontSize = size;
  }
  if (face) {
    element.style.fontFamily = face;
  }
}

function isSafeHtmlUrl(value, allowLocalPath) {
  const trimmed = value.trim().replace(/[\u0000-\u001F\u007F\s]+/g, "");

  if (!trimmed) {
    return false;
  }
  if (trimmed.startsWith("#")) {
    return true;
  }
  if (allowLocalPath && !/^[a-zA-Z][a-zA-Z\d+.-]*:/.test(trimmed)) {
    return true;
  }

  try {
    const parsed = new URL(trimmed, window.location.href);
    const safeProtocols = allowLocalPath
      ? ["http:", "https:", "bomd-local:", "data:"]
      : ["http:", "https:", "mailto:"];
    return safeProtocols.includes(parsed.protocol)
      && (parsed.protocol !== "data:" || /^data:image\/(?:png|jpe?g|gif|webp|svg\+xml);base64,/i.test(trimmed));
  } catch {
    return false;
  }
}

function sanitizeInlineStyle(value) {
  return value
    .split(";")
    .map((declaration) => declaration.trim())
    .filter(Boolean)
    .map((declaration) => {
      const separator = declaration.indexOf(":");
      if (separator === -1) {
        return "";
      }

      const property = declaration.slice(0, separator).trim().toLowerCase();
      const styleValue = declaration.slice(separator + 1).trim();

      if (!property || !styleValue || /\\|\/\*|\*\/|(?:url|image-set|cross-fade|image|paint|src|element|attr|expression)\s*\(|javascript:|@import/i.test(declaration)) {
        return "";
      }

      return `${property}: ${styleValue}`;
    })
    .filter(Boolean)
    .join("; ");
}

function adaptInlineStylesToTheme(root) {
  root.querySelectorAll("[style]").forEach((element) => {
    const background = parseCssColor(element.style.backgroundColor);
    if (!background || background.alpha < 0.2 || colorLuminance(background) < 0.72) {
      return;
    }

    element.style.setProperty("--bomd-inline-background", element.style.backgroundColor);
    element.style.backgroundColor = "var(--html-surface, var(--bomd-inline-background))";

    const foreground = parseCssColor(element.style.color);
    if (foreground && colorLuminance(foreground) < 0.5) {
      element.style.setProperty("--bomd-inline-color", element.style.color);
      element.style.color = "var(--html-foreground, var(--bomd-inline-color))";
    }

    ["borderTopColor", "borderRightColor", "borderBottomColor", "borderLeftColor"].forEach((property) => {
      const borderColor = parseCssColor(element.style[property]);
      if (borderColor && borderColor.alpha >= 0.2 && colorLuminance(borderColor) >= 0.5) {
        element.style.setProperty(`--bomd-inline-${property}`, element.style[property]);
        element.style[property] = `var(--html-border, var(--bomd-inline-${property}))`;
      }
    });
  });
}

function parseCssColor(value) {
  const color = value.trim().toLowerCase();
  const namedColors = {
    black: [0, 0, 0],
    gray: [128, 128, 128],
    silver: [192, 192, 192],
    white: [255, 255, 255]
  };

  if (namedColors[color]) {
    const [red, green, blue] = namedColors[color];
    return { red, green, blue, alpha: 1 };
  }

  const hex = color.match(/^#([\da-f]{3}|[\da-f]{6}|[\da-f]{8})$/i);
  if (hex) {
    const expanded = hex[1].length === 3
      ? hex[1].split("").map((part) => `${part}${part}`).join("")
      : hex[1];
    return {
      red: Number.parseInt(expanded.slice(0, 2), 16),
      green: Number.parseInt(expanded.slice(2, 4), 16),
      blue: Number.parseInt(expanded.slice(4, 6), 16),
      alpha: expanded.length === 8 ? Number.parseInt(expanded.slice(6, 8), 16) / 255 : 1
    };
  }

  const rgb = color.match(/^rgba?\(\s*([\d.]+)\s*,\s*([\d.]+)\s*,\s*([\d.]+)(?:\s*,\s*([\d.]+))?\s*\)$/i);
  if (!rgb) {
    return null;
  }

  return {
    red: Math.min(255, Number.parseFloat(rgb[1])),
    green: Math.min(255, Number.parseFloat(rgb[2])),
    blue: Math.min(255, Number.parseFloat(rgb[3])),
    alpha: rgb[4] === undefined ? 1 : Math.min(1, Number.parseFloat(rgb[4]))
  };
}

function colorLuminance({ red, green, blue }) {
  const channels = [red, green, blue].map((channel) => {
    const value = channel / 255;
    return value <= 0.03928 ? value / 12.92 : ((value + 0.055) / 1.055) ** 2.4;
  });
  return channels[0] * 0.2126 + channels[1] * 0.7152 + channels[2] * 0.0722;
}

function sanitizeHtmlColor(value) {
  const color = value.trim().toLowerCase();

  if (!color) {
    return "";
  }
  if (htmlColorNames.has(color)) {
    return color;
  }
  if (/^#(?:[0-9a-f]{3}|[0-9a-f]{6}|[0-9a-f]{8})$/i.test(color)) {
    return color;
  }
  if (/^(?:rgb|hsl)a?\(\s*[\d.]+%?(?:\s*,\s*|\s+)[\d.]+%?(?:\s*,\s*|\s+)[\d.]+%?(?:\s*(?:,|\/)\s*(?:0|1|0?\.\d+|[\d.]+%))?\s*\)$/i.test(color)) {
    return color;
  }

  return "";
}

function sanitizeFontSize(value) {
  const size = value.trim();
  const legacySizes = {
    "1": "0.72em",
    "2": "0.85em",
    "3": "1em",
    "4": "1.18em",
    "5": "1.4em",
    "6": "1.7em",
    "7": "2em",
    "+1": "1.18em",
    "+2": "1.4em",
    "+3": "1.7em",
    "+4": "2em",
    "-1": "0.85em",
    "-2": "0.72em"
  };

  if (legacySizes[size]) {
    return legacySizes[size];
  }
  if (/^(?:\d+(?:\.\d+)?)(?:px|em|rem|%)$/i.test(size)) {
    return size;
  }

  return "";
}

function sanitizeFontFace(value) {
  const face = value.trim();

  if (!face || /[<>{};()]/.test(face)) {
    return "";
  }

  return face
    .split(",")
    .map((name) => name.trim().replace(/^['"]|['"]$/g, ""))
    .filter(Boolean)
    .map((name) => `"${name.replace(/["\\]/g, "")}"`)
    .join(", ");
}

async function render(payload) {
  const renderSequence = ++activeRenderSequence;
  const root = document.querySelector("#document");
  const source = payload?.source || "";
  const fileName = payload?.fileName || "BoMD";
  const basePath = payload?.basePath || "";
  const targetSourceLine = Number.parseInt(payload?.targetSourceLine || "", 10);
  const rawTargetViewportRatio = Number.parseFloat(payload?.targetViewportRatio || "");
  const targetViewportRatio = Number.isFinite(rawTargetViewportRatio)
    ? Math.min(Math.max(rawTargetViewportRatio, 0), 1)
    : 0.02;
  const signature = `${fileName}:${source.length}:${hashString(source)}`;

  document.title = fileName;

  if (!source.trim()) {
    root.innerHTML = "<p class=\"empty-document\">空文档</p>";
    postRenderSuccess(signature, { fileName, empty: true });
    // Empty documents have no anchor to scroll to, but must still complete
    // the native view's reveal/unlock handshake (even on repeated renders).
    if (Number.isInteger(targetSourceLine) && targetSourceLine > 0) {
      postEvent("render_position_ready", { targetSourceLine });
    }
    return;
  }

  const normalizedSource = normalizeDataImageMarkdown(source);
  const footnoteData = extractFootnotes(normalizedSource);
  footnoteData.trustedMath = {
    nonce: Array.from(crypto.getRandomValues(new Uint32Array(4)), (value) => value.toString(16)).join("-"),
    entries: new Map()
  };
  // Template contents have no browsing context: forbidden resources and event
  // attributes never reach the live document, including those in footnotes.
  const template = document.createElement("template");
  template.innerHTML = markdown.render(footnoteData.source, footnoteData);
  appendFootnotes(template.content, footnoteData);
  sanitizeRenderedHtml(template.content);
  restoreKatex(template.content, footnoteData.trustedMath);
  rewriteImageSources(template.content, basePath);
  root.replaceChildren(template.content);
  adaptInlineStylesToTheme(root);
  enhanceTaskLists(root);
  enhanceTableLayout(root);
  bindImageFallbacks(root);
  bindCodeActions(root);
  bindAnchorLinks(root);
  bindDocumentScrollbar(root);
  bindFootnotePopovers(root);
  bindSelectionHighlight();
  bindSourceLineFocusTracking();
  bindViewportInteractionTracking();
  scheduleSelectionHighlightUpdate();
  if (Number.isInteger(targetSourceLine) && targetSourceLine > 0) {
    await positionBeforeImagesSettle(targetSourceLine, targetViewportRatio, renderSequence);
  }
  if (renderSequence !== activeRenderSequence) return;
  scheduleSourceLineFocusUpdate();
  postRenderSuccess(signature, {
    fileName,
    targetSourceLine: Number.isInteger(targetSourceLine) ? targetSourceLine : 0,
    codeBlocks: root.querySelectorAll(".code-block").length,
    tables: root.querySelectorAll("table").length,
    images: root.querySelectorAll("img").length,
    formulas: root.querySelectorAll(".katex").length,
    footnotes: footnoteData.footnotes.length
  });

  if (Number.isInteger(targetSourceLine) && targetSourceLine > 0) {
    const interactionVersion = viewportInteractionVersion;
    postEvent("render_position_ready", { targetSourceLine });
    void positionAfterImagesSettle(
      root,
      targetSourceLine,
      targetViewportRatio,
      renderSequence,
      interactionVersion
    ).catch(() => {
      if (renderSequence === activeRenderSequence) {
        postEvent("render_warning", { reason: "late_position_failed" });
      }
    });
  }
}

window.BoMDRenderMarkdown = render;
window.BoMDCaptureSourceLineFocus = captureSourceLineFocus;
window.BoMDCaptureViewportAnchor = captureViewportAnchor;
window.BoMDHandleCopyResult = handleCopyResult;

export {
  addSourceLineAttributesToHtmlBlock,
  classifyTableColumns,
  createHeadingSlug,
  extractFootnotes,
  mergeMathSelectionRects,
  normalizeDataImageMarkdown,
  scrollToAnchorTarget
};

function captureSourceLineFocus() {
  reportSourceLineFocus({ force: true });
}

function bindSourceLineFocusTracking() {
  if (sourceLineFocusBound) {
    return;
  }
  sourceLineFocusBound = true;

  document.querySelector("#document-scroll-area")
    ?.addEventListener("scroll", scheduleSourceLineFocusUpdate, { passive: true });
  window.addEventListener("scroll", scheduleSourceLineFocusUpdate, { passive: true });
  window.addEventListener("resize", scheduleSourceLineFocusUpdate);
}

function bindViewportInteractionTracking() {
  if (viewportInteractionTrackingBound) {
    return;
  }
  viewportInteractionTrackingBound = true;

  const markInteraction = () => {
    viewportInteractionVersion += 1;
  };
  const scrollArea = document.querySelector("#document-scroll-area");
  scrollArea?.addEventListener("wheel", markInteraction, { passive: true });
  scrollArea?.addEventListener("touchstart", markInteraction, { passive: true });
  scrollArea?.addEventListener("pointerdown", markInteraction, { passive: true });
  window.addEventListener("keydown", (event) => {
    if (["ArrowDown", "ArrowUp", "End", "Home", "PageDown", "PageUp", " "].includes(event.key)) {
      markInteraction();
    }
  });
}

function scheduleSourceLineFocusUpdate() {
  if (sourceLineFocusFrame) {
    return;
  }

  sourceLineFocusFrame = window.requestAnimationFrame(() => {
    sourceLineFocusFrame = 0;
    reportSourceLineFocus();
  });
}

function reportSourceLineFocus(options = {}) {
  const anchor = captureViewportAnchor();
  if (!anchor) {
    return;
  }

  const signature = `${anchor.line}:${anchor.viewportRatio}:${anchor.kind}`;
  if (options.force || signature !== lastReportedSourceAnchor) {
    lastReportedSourceAnchor = signature;
    postEvent("source_line_focus", anchor);
  }
}

function captureViewportAnchor() {
  const viewport = documentViewport();
  if (viewport.height <= 0) {
    return null;
  }

  const middleY = viewport.top + viewport.height * 0.5;
  const headings = visibleSourceElements(sourceHeadingSelector, viewport);
  const upperHeading = headings.find((item) => item.rect.top + item.rect.height * 0.5 <= middleY);
  if (upperHeading) {
    return {
      line: upperHeading.startLine,
      viewportRatio: 0.02,
      kind: "heading"
    };
  }

  const lowerHeading = headings.find((item) => item.rect.top + item.rect.height * 0.5 > middleY);
  if (lowerHeading) {
    return {
      line: lowerHeading.startLine,
      viewportRatio: 0.5,
      kind: "heading"
    };
  }

  const referenceY = viewport.top + viewport.height * 0.38;
  const candidates = visibleSourceElements(sourceLineBlockSelector, viewport)
    .sort((first, second) => {
      const distanceDifference = distanceToRect(referenceY, first.rect) - distanceToRect(referenceY, second.rect);
      return distanceDifference || first.rect.height - second.rect.height;
    });
  const candidate = candidates[0];
  if (!candidate) {
    return null;
  }

  const progress = candidate.rect.height > 0
    ? Math.min(Math.max((referenceY - candidate.rect.top) / candidate.rect.height, 0), 1)
    : 0;
  const span = Math.max(1, candidate.endLine - candidate.startLine);
  const line = Math.min(candidate.endLine - 1, candidate.startLine + Math.floor(progress * span));

  return {
    line: Math.max(candidate.startLine, line),
    viewportRatio: 0.38,
    kind: sourceElementKind(candidate.element)
  };
}

function documentViewport() {
  const scrollArea = document.querySelector("#document-scroll-area");
  const rect = scrollArea?.getBoundingClientRect();
  return {
    top: rect?.top || 0,
    height: scrollArea?.clientHeight || window.innerHeight
  };
}

function visibleSourceElements(selector, viewport) {
  const bottom = viewport.top + viewport.height;
  return Array.from(document.querySelectorAll(selector))
    .map((element) => {
      const startLine = Number.parseInt(element.dataset.sourceLine, 10);
      const rawEndLine = Number.parseInt(element.dataset.sourceEndLine, 10);
      return {
        element,
        startLine,
        endLine: Number.isInteger(rawEndLine) && rawEndLine >= startLine ? rawEndLine : startLine + 1,
        rect: element.getBoundingClientRect()
      };
    })
    .filter((item) => (
      Number.isInteger(item.startLine)
      && item.startLine > 0
      && item.rect.width > 0
      && item.rect.height > 0
      && item.rect.bottom > viewport.top + 8
      && item.rect.top < bottom - 8
    ))
    .sort((first, second) => first.rect.top - second.rect.top);
}

function distanceToRect(y, rect) {
  if (y >= rect.top && y <= rect.bottom) {
    return 0;
  }
  return Math.min(Math.abs(y - rect.top), Math.abs(y - rect.bottom));
}

function sourceElementKind(element) {
  if (element.closest(".code-block")) return "code";
  if (element.closest(".table-wrap, table")) return "table";
  if (element.closest(".math-scroll")) return "math";
  if (element.closest("li, ul, ol")) return "list";
  if (element.closest("blockquote")) return "quote";
  if (element.closest("figure, img")) return "image";
  return "content";
}

async function positionBeforeImagesSettle(targetLine, viewportRatio, renderSequence) {
  await nextFrame();
  if (renderSequence !== activeRenderSequence) {
    return;
  }

  scrollToSourceLine(targetLine, viewportRatio);
  await nextFrame();
  if (renderSequence === activeRenderSequence) {
    scrollToSourceLine(targetLine, viewportRatio);
  }
}

async function positionAfterImagesSettle(
  root,
  targetLine,
  viewportRatio,
  renderSequence,
  interactionVersion
) {
  await waitForImages(root);
  await waitForStableLayout();
  if (
    renderSequence !== activeRenderSequence
    || interactionVersion !== viewportInteractionVersion
  ) {
    return;
  }

  // WKWebView can schedule one more layout pass immediately after image decoding.
  scrollToSourceLine(targetLine, viewportRatio);
  await nextFrame();
  if (
    renderSequence === activeRenderSequence
    && interactionVersion === viewportInteractionVersion
  ) {
    scrollToSourceLine(targetLine, viewportRatio);
  }
}

function waitForImages(root) {
  const images = Array.from(root.querySelectorAll("img"));
  if (!images.length) {
    return Promise.resolve();
  }

  const settled = images.map((image) => new Promise((resolve) => {
    if (image.complete) {
      resolve();
      return;
    }

    image.addEventListener("load", resolve, { once: true });
    image.addEventListener("error", resolve, { once: true });
  }));

  return Promise.race([
    Promise.all(settled),
    new Promise((resolve) => window.setTimeout(resolve, 4000))
  ]);
}

async function waitForStableLayout() {
  let previousHeight = -1;

  for (let frame = 0; frame < 4; frame += 1) {
    await nextFrame();
    const height = document.querySelector("#document-scroll-area")?.scrollHeight ?? 0;
    if (height === previousHeight) {
      return;
    }
    previousHeight = height;
  }
}

function nextFrame() {
  return new Promise((resolve) => window.requestAnimationFrame(resolve));
}

function scrollToSourceLine(targetLine, viewportRatio = 0.02) {
  const blocks = Array.from(document.querySelectorAll(sourceLineBlockSelector))
    .map((block) => ({
      block,
      line: Number.parseInt(block.dataset.sourceLine, 10),
      endLine: Number.parseInt(block.dataset.sourceEndLine, 10)
    }))
    .filter((item) => Number.isInteger(item.line) && item.line > 0)
    .map((item) => ({
      ...item,
      endLine: Number.isInteger(item.endLine) && item.endLine >= item.line ? item.endLine : item.line + 1
    }))
    .sort((first, second) => first.line - second.line);

  if (!blocks.length) {
    return;
  }

  const containingTargets = blocks
    .filter((item) => item.line <= targetLine && targetLine < item.endLine)
    .sort((first, second) => (first.endLine - first.line) - (second.endLine - second.line));
  const target = containingTargets[0]
    || blocks.find((item) => item.line >= targetLine)
    || blocks[blocks.length - 1];
  const scrollArea = document.querySelector("#document-scroll-area");
  if (!scrollArea) {
    return;
  }
  const rect = target.block.getBoundingClientRect();
  const span = Math.max(1, target.endLine - target.line);
  const progress = Math.min(Math.max((targetLine - target.line) / span, 0), 1);
  const targetY = rect.top + rect.height * progress;
  const scrollRect = scrollArea.getBoundingClientRect();
  const viewportHeight = scrollArea.clientHeight || window.innerHeight;
  const desiredY = scrollRect.top + viewportHeight * Math.min(Math.max(viewportRatio, 0), 1);
  const maxTop = Math.max(0, scrollArea.scrollHeight - viewportHeight);
  const top = Math.min(Math.max(0, scrollArea.scrollTop + targetY - desiredY), maxTop);

  scrollArea.scrollTo(0, top);
  lastReportedSourceAnchor = "";
}

function postEvent(event, metadata = {}) {
  window.webkit?.messageHandlers?.bomd?.postMessage({ event, ...metadata });
}

function postRenderSuccess(signature, metadata) {
  if (signature === lastRenderSignature) {
    return;
  }
  lastRenderSignature = signature;
  postEvent("render_success", metadata);
}

function hashString(value) {
  let hash = 0;
  for (let index = 0; index < value.length; index += 1) {
    hash = ((hash << 5) - hash + value.charCodeAt(index)) | 0;
  }
  return hash;
}

function handleCopyResult(payload) {
  const requestID = payload?.requestID || "";
  const pending = pendingCopyButtons.get(requestID);

  if (!pending) {
    return;
  }

  pendingCopyButtons.delete(requestID);

  if (!payload?.success || !pending.cluster) {
    return;
  }

  pending.cluster.classList.remove("is-copied");
  void pending.cluster.offsetWidth;
  pending.cluster.classList.add("is-copied");

  window.setTimeout(() => {
    pending.cluster?.classList.remove("is-copied");
  }, 1200);
}
