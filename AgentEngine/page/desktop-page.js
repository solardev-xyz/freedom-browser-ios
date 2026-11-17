// Copied unchanged from desktop Freedom (freedom-browser main e17c9d011),
// src/main/automation/adapters/web-contents-page-adapter.js lines 183-1246:
// the page-side functions desktop injects into its isolated world. Keep this
// file identical to desktop so fixes can be copied across; iPhone-specific
// input lives in page/index.js.
/* eslint-disable */

function readElementName(element) {
  const normalize = (value) =>
    String(value || '')
      .replace(/\s+/g, ' ')
      .trim();
  const labelledBy = element.getAttribute('aria-labelledby');
  if (labelledBy) {
    const root = element.getRootNode();
    const name = normalize(
      labelledBy
        .split(/\s+/)
        .map((id) => root.getElementById?.(id)?.textContent || '')
        .join(' ')
    );
    if (name) return name;
  }
  const ariaLabel = normalize(element.getAttribute('aria-label'));
  if (ariaLabel) return ariaLabel;
  // The browser resolves explicit, wrapping and multiple labels in tree order,
  // within the control's own document/shadow root.
  const associatedLabel = normalize(
    Array.from(element.labels || [], (label) => {
      const parts = [];
      const walker = label.ownerDocument.createTreeWalker(label, NodeFilter.SHOW_TEXT);
      for (let node = walker.nextNode(); node; node = walker.nextNode()) {
        // A wrapping label must not absorb the labelled control's own subtree
        // (notably every option of a select or the contents of a textarea).
        if (!element.contains(node)) parts.push(node.textContent || '');
      }
      return parts.join('');
    }).join(' ')
  );
  if (associatedLabel) return associatedLabel;
  return normalize(
    element.getAttribute('alt') ||
      element.getAttribute('title') ||
      element.getAttribute('placeholder') ||
      element.innerText ||
      (element.tagName === 'INPUT' && ['button', 'submit', 'reset'].includes(element.type)
        ? element.value
        : '')
  );
}

function readScrollState(element) {
  const view = element.ownerDocument.defaultView;
  const style = view.getComputedStyle(element);
  const isViewport = element === element.ownerDocument.scrollingElement;
  const permits = (overflow) =>
    isViewport ? !['hidden', 'clip'].includes(overflow) : ['auto', 'scroll'].includes(overflow);
  const width = isViewport ? view.innerWidth : element.clientWidth;
  const height = isViewport ? view.innerHeight : element.clientHeight;
  const rangeX = Math.max(0, element.scrollWidth - element.clientWidth);
  const rangeY = Math.max(0, element.scrollHeight - element.clientHeight);
  const rtl = style.direction === 'rtl';
  return {
    x: element.scrollLeft,
    y: element.scrollTop,
    width,
    height,
    minX: rtl ? -rangeX : 0,
    maxX: rtl ? 0 : rangeX,
    maxY: rangeY,
    horizontal: permits(style.overflowX) && rangeX > 1,
    vertical: permits(style.overflowY) && rangeY > 1,
  };
}

// No scrolling/focusing during inspection. Only wheel points whose nearest
// scroll container is the requested reference are eligible; this avoids
// accidentally scrolling an inner list when the caller requested the page.
function inspectScrollReference(ref, direction, requirePoint = true) {
  const reference = globalThis.__FREEDOM_AUTOMATION_ELEMENT_REFERENCES__?.refs?.get(ref);
  if (!reference) return { ok: false, reason: 'changed' };
  const { element, frameWindow } = reference;
  if (!reference.scrollTarget) return { ok: false, reason: 'not_interactable' };
  try {
    if (!element.isConnected || element.ownerDocument !== frameWindow.document) {
      return { ok: false, reason: 'changed' };
    }
    const scroll = readScrollState(element);
    if (!requirePoint) return { ok: true, scroll };
    const horizontal = ['left', 'right'].includes(direction);
    const axis = horizontal ? 'horizontal' : 'vertical';
    if (!scroll[axis]) return { ok: true, scroll, boundary: true };
    const coordinate = horizontal ? scroll.x : scroll.y;
    const minimum = horizontal ? scroll.minX : 0;
    const maximum = horizontal ? scroll.maxX : scroll.maxY;
    const forward = ['down', 'right'].includes(direction);
    if (forward ? coordinate >= maximum - 1 : coordinate <= minimum + 1) {
      return { ok: true, scroll, boundary: true };
    }
    const parentOf = (node) => node.parentElement || node.getRootNode()?.host;
    const deepestHit = (root, x, y) => {
      let hit = root.elementFromPoint(x, y);
      while (hit?.shadowRoot) {
        const nested = hit.shadowRoot.elementFromPoint(x, y);
        if (!nested || nested === hit) break;
        hit = nested;
      }
      return hit;
    };
    const isViewport = element === element.ownerDocument.scrollingElement;
    const rect = isViewport
      ? { left: 0, top: 0, right: frameWindow.innerWidth, bottom: frameWindow.innerHeight }
      : element.getBoundingClientRect();
    const left = Math.max(0, rect.left),
      top = Math.max(0, rect.top);
    const right = Math.min(frameWindow.innerWidth, rect.right);
    const bottom = Math.min(frameWindow.innerHeight, rect.bottom);
    if (right - left < 2 || bottom - top < 2) return { ok: false, reason: 'not_interactable' };
    let framedPoint = null;
    for (const fy of [0.5, 0.15, 0.85]) {
      for (const fx of [0.5, 0.15, 0.85]) {
        let x = Math.floor(left + (right - left) * fx);
        let y = Math.floor(top + (bottom - top) * fy);
        let hit = deepestHit(element.ownerDocument, x, y);
        // A wheel over a child frame is dispatched to that frame's document,
        // which the delivery probe cannot see (and, cross-origin, cannot reach).
        const overChildFrame = ['IFRAME', 'FRAME', 'EMBED', 'OBJECT'].includes(
          hit?.tagName?.toUpperCase()
        );
        let nearest = null;
        while (hit) {
          if (readScrollState(hit)[axis]) {
            nearest = hit;
            break;
          }
          hit = parentOf(hit);
        }
        if (nearest !== element) continue;
        let view = frameWindow;
        let usable = true;
        while (view !== window) {
          const frame = view.frameElement;
          if (!frame) return { ok: false, reason: 'changed' };
          // Coordinate conversion below supports ordinary same-origin frames.
          // Transformed frames require a different geometry path.
          for (let ancestor = frame; ancestor; ancestor = parentOf(ancestor)) {
            if (ancestor.ownerDocument.defaultView.getComputedStyle(ancestor).transform !== 'none')
              usable = false;
          }
          const frameRect = frame.getBoundingClientRect();
          x += frameRect.left + frame.clientLeft;
          y += frameRect.top + frame.clientTop;
          view = view.parent;
          if (deepestHit(view.document, x, y) !== frame) usable = false;
        }
        if (usable && x >= 0 && y >= 0 && x < view.innerWidth && y < view.innerHeight) {
          const found = { x: Math.round(x), y: Math.round(y) };
          if (!overChildFrame) return { ok: true, scroll, point: found };
          framedPoint ??= found;
        }
      }
    }
    // Only points over a child frame: still usable, but the wheel's delivery
    // cannot be observed there, so the caller must not resend it.
    if (framedPoint) return { ok: true, scroll, point: framedPoint, childFrame: true };
    return { ok: false, reason: 'not_interactable' };
  } catch {
    return { ok: false, reason: 'changed' };
  }
}

function readControlState(element, role) {
  const checkedRoles = new Set([
    'checkbox',
    'radio',
    'switch',
    'menuitemcheckbox',
    'menuitemradio',
    'option',
    'treeitem',
  ]);
  const selectedRoles = new Set([
    'option',
    'tab',
    'row',
    'gridcell',
    'columnheader',
    'rowheader',
    'treeitem',
  ]);
  const expandedRoles = new Set([
    'application',
    'button',
    'checkbox',
    'combobox',
    'gridcell',
    'link',
    'listbox',
    'menuitem',
    'row',
    'rowheader',
    'columnheader',
    'tab',
    'treeitem',
    'menuitemcheckbox',
    'menuitemradio',
    'switch',
  ]);
  const result = {};
  const ariaState = (attribute, mixed = false) => {
    const value = element.getAttribute(attribute)?.trim().toLowerCase();
    if (value === 'true' || value === 'false') return value === 'true';
    if (mixed && value === 'mixed') return 'mixed';
    return undefined;
  };
  const add = (key, value) => {
    if (value !== undefined) result[key] = value;
  };
  if (element.tagName === 'INPUT' && ['checkbox', 'radio'].includes(element.type)) {
    // Native state wins over conflicting ARIA markup.
    result.checked =
      element.type === 'checkbox' && element.indeterminate ? 'mixed' : element.checked;
  } else if (checkedRoles.has(role)) {
    const checked = ariaState('aria-checked', true);
    add(
      'checked',
      checked === 'mixed' && ['radio', 'menuitemradio', 'switch'].includes(role) ? false : checked
    );
  }
  if (['INPUT', 'SELECT', 'TEXTAREA'].includes(element.tagName)) {
    result.required = element.required === true;
    result.readOnly = element.readOnly === true;
    if (element.willValidate && element.validity) {
      result.valid = element.validity.valid;
      result.validation = ['valueMissing', 'typeMismatch', 'patternMismatch', 'tooLong',
        'tooShort', 'rangeUnderflow', 'rangeOverflow', 'stepMismatch', 'badInput', 'customError']
        .filter((key) => element.validity[key]);
    }
  }
  if (role === 'button') add('pressed', ariaState('aria-pressed', true));
  if (selectedRoles.has(role)) add('selected', ariaState('aria-selected'));
  if (expandedRoles.has(role)) add('expanded', ariaState('aria-expanded'));
  return result;
}

function collectPageSnapshot(
  maxTextLength,
  maxElements,
  maxRetainedReferences,
  maxSelectOptions,
  snapshotToken,
  { query = '', textQuery = '', elementOffset = 0, textOffset = 0 } = {}
) {
  const stateKey = '__FREEDOM_AUTOMATION_ELEMENT_REFERENCES__';
  const state = globalThis[stateKey] || { refs: new Map() };
  globalThis[stateKey] = state;
  const normalize = (value) =>
    String(value || '')
      .replace(/\s+/g, ' ')
      .trim();
  let fieldsTruncated = false;
  const shorten = (value, limit = 2_000) => {
    const text = String(value || '');
    if (text.length <= limit) return text;
    fieldsTruncated = true;
    const end = /[\uD800-\uDBFF]/.test(text[limit - 1]) ? limit - 1 : limit;
    return text.slice(0, end);
  };
  const displayField = (key, value, limit) => {
    const text = String(value || '');
    return {
      [key]: shorten(text, limit),
      ...(text.length > (limit || 2_000) && { [`${key}Truncated`]: true }),
    };
  };
  // URL and option values are identities, not display text. Omit oversized
  // values rather than returning a shortened string that looks actionable.
  const exactField = (key, value, limit) => {
    if (value.length <= limit) return { [key]: value };
    fieldsTruncated = true;
    return { [`${key}Omitted`]: true };
  };
  const encodedSize = (value) => new TextEncoder().encode(JSON.stringify(value)).length;
  let elementBytes = 0;
  let elementBudgetReached = false;
  let frameBytes = 0;
  const addFrame = (frame) => {
    if (frameBytes + encodedSize(frame) > 32_000) {
      fieldsTruncated = true;
      frame = {
        frameId: frame.frameId,
        parentFrameId: frame.parentFrameId,
        depth: frame.depth,
        accessible: frame.accessible,
        ...(frame.viewport && { viewport: frame.viewport }),
        metadataOmitted: true,
      };
    }
    frameBytes += encodedSize(frame);
    frames.push(frame);
  };
  const selectState = (element) => {
    const result = { multiple: element.multiple, ...exactField('value', element.value, 2_000), options: [] };
    let bytes = 0;
    for (let index = 0; index < Math.min(element.options.length, maxSelectOptions); index += 1) {
      const option = element.options[index];
      if (option.value.length > 2_000) {
        result.optionsTruncated = true;
        continue;
      }
      const entry = {
        value: option.value,
        ...displayField('label', normalize(option.label || option.textContent)),
        disabled: option.matches(':disabled'),
        selected: option.selected,
      };
      const size = encodedSize(entry);
      if (bytes + size > 8_000) {
        result.optionsTruncated = true;
        continue;
      }
      bytes += size;
      result.options.push(entry);
    }
    if (element.options.length > maxSelectOptions) result.optionsTruncated = true;
    if (result.optionsTruncated) fieldsTruncated = true;
    return result;
  };
  const styleCache = new WeakMap();
  const styleFor = (element) => {
    let style = styleCache.get(element);
    if (!style) {
      style = element.ownerDocument.defaultView.getComputedStyle(element);
      styleCache.set(element, style);
    }
    return style;
  };
  const visible = (element) => {
    const style = styleFor(element);
    if (style.display === 'none' || style.visibility === 'hidden' || style.opacity === '0') {
      return false;
    }
    return element.getClientRects().length > 0;
  };
  const implicitRole = (element) => {
    const tag = element.tagName.toLowerCase();
    if (tag === 'a' && element.hasAttribute('href')) return 'link';
    if (tag === 'button') return 'button';
    if (tag === 'select') return element.multiple || element.size > 1 ? 'listbox' : 'combobox';
    if (tag === 'textarea') return 'textbox';
    if (tag === 'dialog') return 'dialog';
    if (tag === 'input') {
      if (element.type === 'file') return 'button';
      if (['button', 'submit', 'reset'].includes(element.type)) return 'button';
      if (element.type === 'checkbox') return 'checkbox';
      if (element.type === 'radio') return 'radio';
      if (element.type === 'range') return 'slider';
      return 'textbox';
    }
    return element.isContentEditable ? 'textbox' : 'generic';
  };
  const semanticCandidateSelector =
    'a[href],button,input:not([type="hidden"]),select,textarea,dialog[open],[role],[contenteditable="true"],[tabindex]:not([tabindex="-1"])';
  const isExplicitClickTarget = (element) =>
    element.hasAttribute('onclick') || typeof element.onclick === 'function';
  const isPointerBoundary = (element) => {
    if (['HTML', 'BODY'].includes(element.tagName)) return false;
    if (styleFor(element).cursor !== 'pointer') return false;
    const parent = element.parentElement;
    // Cursor is inherited. Keep the outer boundary so a clickable card and
    // each of its text/icon descendants do not all become separate targets.
    return !parent || styleFor(parent).cursor !== 'pointer';
  };
  const elements = [];
  const dialogs = [];
  let dialogsTruncated = false;
  const frames = [];
  const pageText = [];
  const textSources = [];
  let collectedTextLength = 0;
  let candidateCount = 0;
  let visitedNodes = 0;
  let scanTruncated = false;
  let textCollectionTruncated = false;
  let remainingText = 1_000_000;
  const search = normalize(query).toLowerCase();

  const composedActiveElement = (frameDocument) => {
    let active = frameDocument.activeElement;
    while (active?.shadowRoot?.activeElement) active = active.shadowRoot.activeElement;
    return active;
  };

  const visitDocument = (frameWindow, parentFrameId, depth, frameElement) => {
    if (depth > 16 || frames.length >= 64 || visitedNodes >= 20_000) {
      scanTruncated = true;
      return;
    }
    const frameId = depth === 0 ? 'frame_main' : `frame_${snapshotToken}_${String(frames.length)}`;
    let frameDocument;
    try {
      frameDocument = frameWindow.document;
      void frameDocument.documentElement;
    } catch {
      addFrame({
        frameId,
        parentFrameId,
        depth,
        ...displayField('name', frameElement?.getAttribute('name') || ''),
        ...exactField('url', frameElement?.src || '', 8_192),
        accessible: false,
      });
      return;
    }

    const viewportRef = `${frameId}_${snapshotToken}_viewport`;
    const scrollingElement = frameDocument.scrollingElement;
    const viewport = scrollingElement
      ? { ref: viewportRef, ...readScrollState(scrollingElement) }
      : null;
    if (scrollingElement)
      state.refs.set(viewportRef, { element: scrollingElement, frameWindow, scrollTarget: true });
    addFrame({
      ...(viewport && { viewport }),
      frameId,
      parentFrameId,
      depth,
      ...displayField('name', frameElement?.getAttribute('name') || ''),
      ...exactField('url', frameWindow.location.href, 8_192),
      accessible: true,
    });
    // innerText retains the browser's rendered-text semantics. Its layout cost
    // is browser-owned; these limits bound retained text and our own traversal,
    // not a hard deadline for Chromium's layout work.
    const rawText = frameDocument.body?.innerText || '';
    if (rawText.length > remainingText) textCollectionTruncated = true;
    const text = normalize(rawText.slice(0, remainingText));
    remainingText = Math.max(0, remainingText - rawText.length);
    if (text) {
      const start = collectedTextLength + (pageText.length ? 1 : 0);
      pageText.push(text);
      textSources.push({ frameId, start, end: start + text.length });
      collectedTextLength = start + text.length;
    }

    const childFrames = [];
    const visitRoot = (root, shadowDepth = 0) => {
      if (shadowDepth > 16) {
        scanTruncated = true;
        return;
      }
      const shadowRoots = [];
      const walker = frameDocument.createTreeWalker(root, NodeFilter.SHOW_ELEMENT);
      for (let element = walker.nextNode(); element; element = walker.nextNode()) {
        if (visitedNodes >= 20_000) {
          scanTruncated = true;
          break;
        }
        visitedNodes += 1;
        if (element.shadowRoot) shadowRoots.push(element.shadowRoot);
        if (element.matches('iframe,frame')) childFrames.push(element);
        if (
          element.matches('dialog[open],[role="dialog"],[role="alertdialog"]') &&
          visible(element)
        ) {
          if (dialogs.length < 16)
            dialogs.push({
              frameId,
              role: element.getAttribute('role') || 'dialog',
              name: readElementName(element).slice(0, 240),
              modal: element.matches(':modal') || element.getAttribute('aria-modal') === 'true',
            });
          else dialogsTruncated = true;
        }
        if (element === frameDocument.scrollingElement) continue;
        const scroll = readScrollState(element);
        const scrollable = scroll.horizontal || scroll.vertical;
        const semantic = element.matches(semanticCandidateSelector);
        const inferred =
          !semantic && (isExplicitClickTarget(element) || isPointerBoundary(element));
        if (!semantic && !inferred && !scrollable) continue;
        if (!visible(element)) continue;
        const name = readElementName(element);
        if (inferred && !name && !scrollable) continue;
        if (search && !name.toLowerCase().includes(search)) continue;
        candidateCount += 1;
        if (
          candidateCount <= elementOffset ||
          elements.length >= maxElements ||
          elementBudgetReached
        )
          continue;
        const role =
          element.getAttribute('role') ||
          (inferred ? 'button' : scrollable && !semantic ? 'region' : implicitRole(element));
        const ref = `${snapshotToken}_${String(elements.length)}`;
        const tag = element.tagName.toLowerCase();
        const inputType = normalize(element.getAttribute('type')).toLowerCase();
        const uploadsFile = tag === 'input' && inputType === 'file';
        const submitsForm =
          Boolean(element.form) &&
          ((tag === 'button' && (!inputType || inputType === 'submit')) ||
            (tag === 'input' && ['submit', 'image'].includes(inputType)));
        const downloadsFile =
          tag === 'a' && element.hasAttribute('href') && element.hasAttribute('download');
        const entry = {
          ref,
          frameId,
          ...displayField('role', role, 128),
          ...displayField('name', name),
          ...displayField('tag', tag, 128),
          ...(element.closest('dialog[open],[role="dialog"],[role="alertdialog"]') && {
            inDialog: true,
          }),
          ...(inferred && { inferred: true }),
          disabled:
            element.matches(':disabled') || element.getAttribute('aria-disabled') === 'true',
          focused: element === composedActiveElement(frameDocument),
          editable:
            (!uploadsFile && element.matches('input:not([readonly]),textarea:not([readonly])')) ||
            element.isContentEditable,
          ...readControlState(element, role),
          ...(scrollable && { scrollable: scroll }),
          ...(scrollable && !semantic && !inferred && { scrollOnly: true }),
          ...(uploadsFile
            ? { effect: 'file_upload' }
            : downloadsFile
              ? { effect: 'file_download' }
              : submitsForm
                ? { effect: 'form_submission' }
                : {}),
          ...(uploadsFile && {
            accept: normalize(element.getAttribute('accept')).slice(0, 500),
            multiple: element.multiple === true,
          }),
          ...(tag === 'select' && selectState(element)),
        };
        const size = encodedSize(entry);
        if (elementBytes + size > 128_000) {
          elementBudgetReached = true;
          continue;
        }
        elementBytes += size;
        state.refs.set(ref, { element, frameWindow, scrollTarget: scrollable });
        elements.push(entry);
      }
      for (const shadowRoot of shadowRoots) {
        if (visitedNodes >= 20_000) {
          scanTruncated = true;
          break;
        }
        visitRoot(shadowRoot, shadowDepth + 1);
      }
    };

    visitRoot(frameDocument);

    for (const childFrame of childFrames) {
      const childWindow = childFrame.contentWindow;
      if (childWindow) visitDocument(childWindow, frameId, depth + 1, childFrame);
    }
  };

  visitDocument(window, null, 0, null);
  while (state.refs.size > maxRetainedReferences) {
    state.refs.delete(state.refs.keys().next().value);
  }

  const fullText = pageText.join(' ');
  // Offsets count UTF-16 code units, but emitted pages must not split a pair.
  let textStart = Math.min(textOffset, fullText.length);
  if (
    textStart > 0 &&
    /[\uDC00-\uDFFF]/.test(fullText[textStart] || '') &&
    /[\uD800-\uDBFF]/.test(fullText[textStart - 1])
  )
    textStart -= 1;
  let textMatch = null;
  let excerptLength = maxTextLength;
  if (textQuery) {
    // Escape literal text rather than allowing model-supplied regular expressions.
    // Unicode regexp indices stay in the original text, unlike lowercasing it
    // first (which can change the length of characters such as dotted I).
    const literal = normalize(textQuery).replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
    let matchedSource;
    for (const source of textSources) {
      const from = Math.max(textStart, source.start);
      if (from >= source.end) continue;
      const match = new RegExp(literal, 'iu').exec(fullText.slice(from, source.end));
      if (!match) continue;
      const start = from + match.index;
      textMatch = { start, end: start + match[0].length, frameId: source.frameId };
      matchedSource = source;
      break;
    }
    if (textMatch) {
      textStart = Math.max(matchedSource.start, textMatch.start - 240);
      if (/[\uDC00-\uDFFF]/.test(fullText[textStart] || '') && textStart > 0) textStart -= 1;
      excerptLength = Math.min(matchedSource.end, textMatch.end + 240) - textStart;
    } else {
      excerptLength = 0;
    }
  }
  let textEnd = Math.min(textStart + excerptLength, fullText.length);
  if (
    textEnd < fullText.length &&
    /[\uDC00-\uDFFF]/.test(fullText[textEnd]) &&
    /[\uD800-\uDBFF]/.test(fullText[textEnd - 1])
  )
    textEnd -= 1;
  const moreElements = candidateCount > elementOffset + elements.length;
  const moreText = textEnd < fullText.length;

  return {
    ...exactField('url', window.location.href, 8_192),
    ...displayField('title', document.title),
    text: fullText.slice(textStart, textEnd),
    pageToolsAvailable: typeof document.modelContext?.getTools === 'function',
    frames,
    elements,
    dialogs,
    dialogsTruncated,
    elementOffset,
    textOffset: textStart,
    ...(query && { query }),
    ...(moreElements && { nextElementOffset: elementOffset + elements.length }),
    ...(!textQuery && moreText && { nextTextOffset: textEnd }),
    ...(textQuery && {
      textQuery,
      textMatch,
      ...(textMatch && textMatch.end < fullText.length && { nextMatchOffset: textMatch.end }),
    }),
    elementsTruncated: moreElements || scanTruncated,
    textTruncated: moreText || textCollectionTruncated || scanTruncated,
    scanTruncated,
    textCollectionTruncated,
    fieldsTruncated,
    truncated:
      moreElements ||
      moreText ||
      scanTruncated ||
      textCollectionTruncated ||
      fieldsTruncated ||
      dialogsTruncated,
  };
}

function inspectReferencedElement(ref, action) {
  const state = globalThis.__FREEDOM_AUTOMATION_ELEMENT_REFERENCES__;
  const reference = state?.refs?.get(ref);
  if (!reference) return { ok: false, reason: 'changed' };
  const { element, frameWindow } = reference;
  try {
    if (!element.isConnected || element.ownerDocument !== frameWindow.document) {
      return { ok: false, reason: 'changed' };
    }
  } catch {
    return { ok: false, reason: 'changed' };
  }

  const style = frameWindow.getComputedStyle(element);
  const unavailable =
    style.display === 'none' ||
    style.visibility === 'hidden' ||
    style.opacity === '0' ||
    element.getClientRects().length === 0 ||
    element.matches(':disabled') ||
    element.getAttribute('aria-disabled') === 'true';
  if (unavailable) return { ok: false, reason: 'not_interactable' };

  if (action === 'verify_focus') {
    let active = element.ownerDocument.activeElement;
    while (active?.shadowRoot?.activeElement) active = active.shadowRoot.activeElement;
    return active === element ? { ok: true } : { ok: false, reason: 'not_interactable' };
  }

  if (action === 'upload') {
    const tag = element.tagName.toLowerCase();
    const inputType = String(element.getAttribute('type') || '').toLowerCase();
    return tag === 'input' && inputType === 'file'
      ? { ok: true }
      : { ok: false, reason: 'not_interactable' };
  }

  if (action === 'click') {
    element.scrollIntoView({ block: 'center', inline: 'center' });
    let ancestorWindow = frameWindow;
    while (ancestorWindow !== window) {
      const ancestorFrame = ancestorWindow.frameElement;
      if (!ancestorFrame) return { ok: false, reason: 'changed' };
      ancestorFrame.scrollIntoView({ block: 'center', inline: 'center' });
      ancestorWindow = ancestorWindow.parent;
    }

    const rect = element.getBoundingClientRect();
    let x = rect.left + rect.width / 2;
    let y = rect.top + rect.height / 2;
    const deepElementFromPoint = (root, pointX, pointY) => {
      let hit = root.elementFromPoint(pointX, pointY);
      while (hit?.shadowRoot) {
        const nested = hit.shadowRoot.elementFromPoint(pointX, pointY);
        if (!nested || nested === hit) break;
        hit = nested;
      }
      return hit;
    };
    const hit = deepElementFromPoint(element.ownerDocument, x, y);
    if (!hit || (hit !== element && !element.contains(hit))) {
      return { ok: false, reason: 'not_interactable' };
    }

    let currentWindow = frameWindow;
    while (currentWindow !== window) {
      const currentFrame = currentWindow.frameElement;
      if (!currentFrame) return { ok: false, reason: 'changed' };
      for (
        let ancestor = currentFrame;
        ancestor;
        ancestor = ancestor.parentElement || ancestor.getRootNode()?.host
      ) {
        const style = currentWindow.parent.getComputedStyle(ancestor);
        if (
          ['transform', 'translate', 'rotate', 'scale', 'perspective'].some(
            (key) => style[key] && style[key] !== 'none'
          ) ||
          Number(style.zoom || 1) !== 1
        )
          return { ok: false, reason: 'not_interactable' };
      }
      const frameRect = currentFrame.getBoundingClientRect();
      x += frameRect.left + currentFrame.clientLeft;
      y += frameRect.top + currentFrame.clientTop;
      const parentDocument = currentWindow.parent.document;
      const parentHit = deepElementFromPoint(parentDocument, x, y);
      if (!parentHit || (parentHit !== currentFrame && !currentFrame.contains(parentHit))) {
        return { ok: false, reason: 'not_interactable' };
      }
      currentWindow = currentWindow.parent;
    }
    if (x < 0 || y < 0 || x >= currentWindow.innerWidth || y >= currentWindow.innerHeight) {
      return { ok: false, reason: 'not_interactable' };
    }
    return { ok: true, point: { x: Math.round(x), y: Math.round(y) } };
  }

  const editable =
    element.matches('input:not([readonly]),textarea:not([readonly])') || element.isContentEditable;
  if (action !== 'press' && !editable) return { ok: false, reason: 'not_interactable' };
  element.scrollIntoView({ block: 'center', inline: 'center' });
  element.focus();
  let active = element.ownerDocument.activeElement;
  while (active?.shadowRoot?.activeElement) active = active.shadowRoot.activeElement;
  if (active !== element) {
    return { ok: false, reason: 'not_interactable' };
  }
  return { ok: true, contentEditable: element.isContentEditable };
}

async function describeReferencedElement(ref, action, key) {
  const state = globalThis.__FREEDOM_AUTOMATION_ELEMENT_REFERENCES__;
  const reference = state?.refs?.get(ref);
  if (!reference) return { ok: false, reason: 'changed' };
  const { element, frameWindow } = reference;
  try {
    if (!element.isConnected || element.ownerDocument !== frameWindow.document) {
      return { ok: false, reason: 'changed' };
    }
  } catch {
    return { ok: false, reason: 'changed' };
  }

  const normalize = (value) =>
    String(value || '')
      .replace(/\s+/g, ' ')
      .trim();
  const label = readElementName(element);
  const tag = element.tagName.toLowerCase();
  const inputType = normalize(element.getAttribute('type')).toLowerCase();
  const uploadsFile = action === 'upload' && tag === 'input' && inputType === 'file';
  const submitsForm =
    Boolean(element.form) &&
    ((tag === 'button' && (!inputType || inputType === 'submit')) ||
      (tag === 'input' && ['submit', 'image'].includes(inputType)));
  const activatesElement =
    action === 'click' ||
    action === 'download' ||
    (action === 'press' && ['Enter', 'Space'].includes(key));
  const downloadsFile =
    tag === 'a' &&
    element.hasAttribute('href') &&
    (element.hasAttribute('download') || action === 'download') &&
    activatesElement;
  const implicitlySubmitsForm =
    action === 'press' &&
    key === 'Enter' &&
    Boolean(element.form) &&
    tag === 'input' &&
    ![
      'button',
      'checkbox',
      'color',
      'file',
      'hidden',
      'image',
      'radio',
      'range',
      'reset',
      'submit',
    ].includes(inputType);
  const formSubmission = (submitsForm && activatesElement) || implicitlySubmitsForm;
  let actionLabel = label;
  let navigationTarget = '';
  let formPayloadFingerprint = '';
  if (action === 'select' && tag === 'select') {
    if (element.options.length > 1000 || Array.from(element.options).some(
      (option) => option.value.length > 2000 || option.label.length > 2000
    )) return { ok: false, reason: 'not_interactable' };
    const choices = JSON.stringify({ multiple: element.multiple, options: Array.from(element.options,
      (option) => [option.value, option.label, option.selected, option.matches(':disabled')]) });
    if (choices.length > 200000) return { ok: false, reason: 'not_interactable' };
    const digest = await frameWindow.crypto.subtle.digest('SHA-256', new frameWindow.TextEncoder().encode(choices));
    formPayloadFingerprint = Array.from(new Uint8Array(digest), (byte) => byte.toString(16).padStart(2, '0')).join('');
  }
  if (tag === 'a' && element.hasAttribute('href') && activatesElement) {
    navigationTarget = element.href;
  } else if (formSubmission) {
    const defaultSubmitter = implicitlySubmitsForm
      ? Array.from(element.form.elements).find((candidate) => {
          const candidateTag = candidate.tagName?.toLowerCase();
          const candidateType = normalize(candidate.getAttribute?.('type')).toLowerCase();
          return (
            !candidate.disabled &&
            ((candidateTag === 'button' && (!candidateType || candidateType === 'submit')) ||
              (candidateTag === 'input' && ['submit', 'image'].includes(candidateType)))
          );
        })
      : element;
    if (implicitlySubmitsForm && defaultSubmitter) {
      actionLabel = normalize(
        defaultSubmitter.getAttribute('aria-label') ||
          defaultSubmitter.getAttribute('title') ||
          defaultSubmitter.innerText ||
          defaultSubmitter.value ||
          label
      );
    }
    navigationTarget = defaultSubmitter?.hasAttribute('formaction')
      ? defaultSubmitter.formAction
      : element.form.action;
    const formWindow = element.ownerDocument.defaultView;
    const formData = defaultSubmitter
      ? new formWindow.FormData(element.form, defaultSubmitter)
      : new formWindow.FormData(element.form);
    const entries = Array.from(formData.entries(), ([name, value]) => [
      name,
      typeof value === 'string'
        ? { kind: 'text', value }
        : {
            kind: 'file',
            name: value.name,
            size: value.size,
            type: value.type,
            lastModified: value.lastModified,
          },
    ]);
    const serializedPayload = JSON.stringify({
      action: navigationTarget,
      method: defaultSubmitter?.hasAttribute('formmethod')
        ? defaultSubmitter.formMethod
        : element.form.method,
      enctype: defaultSubmitter?.hasAttribute('formenctype')
        ? defaultSubmitter.formEnctype
        : element.form.enctype,
      target: defaultSubmitter?.hasAttribute('formtarget')
        ? defaultSubmitter.formTarget
        : element.form.target,
      entries,
    });
    const payloadDigest = await formWindow.crypto.subtle.digest(
      'SHA-256',
      new formWindow.TextEncoder().encode(serializedPayload)
    );
    formPayloadFingerprint = Array.from(new Uint8Array(payloadDigest), (byte) =>
      byte.toString(16).padStart(2, '0')
    ).join('');
  }
  return {
    ok: true,
    sensitiveInput: inputType === 'password' || /password|one-time-code/i.test(element.getAttribute('autocomplete') || ''),
    label: actionLabel,
    ...(uploadsFile
      ? { effect: 'file_upload' }
      : downloadsFile
        ? { effect: 'file_download' }
        : formSubmission
          ? { effect: 'form_submission' }
          : {}),
    ...(uploadsFile && {
      accept: normalize(element.getAttribute('accept')).slice(0, 500),
      multiple: element.multiple === true,
    }),
    ...(navigationTarget && { navigationTarget }),
    ...(formPayloadFingerprint && { formPayloadFingerprint }),
  };
}

async function describeFrameReference(ref, operation, key) {
  const reference = globalThis.__FREEDOM_AUTOMATION_ELEMENT_REFERENCES__?.refs?.get(ref);
  if (!reference) return { ok: false, reason: 'changed' };
  const element = reference.element;
  if (element.tagName === 'INPUT' && element.type === 'file')
    return { ok: true, effect: 'file_upload', label: readElementName(element) };
  return describeReferencedElement(ref, operation.replace('browser_', ''), key);
}

function frameViewport() {
  return {
    ok:
      !window.visualViewport ||
      (visualViewport.scale === 1 &&
        visualViewport.offsetLeft === 0 &&
        visualViewport.offsetTop === 0),
    width: innerWidth,
    height: innerHeight,
  };
}

function markReferencedFileInput(ref, marker) {
  const inspected = inspectReferencedElement(ref, 'upload');
  if (!inspected.ok) return inspected;
  const element = globalThis.__FREEDOM_AUTOMATION_ELEMENT_REFERENCES__.refs.get(ref).element;
  element.setAttribute('data-freedom-agent-upload', marker);
  return { ok: true };
}

function clearReferencedFileInputMarker(ref, marker) {
  const reference = globalThis.__FREEDOM_AUTOMATION_ELEMENT_REFERENCES__?.refs?.get(ref);
  const element = reference?.element;
  if (element?.getAttribute('data-freedom-agent-upload') === marker) {
    element.removeAttribute('data-freedom-agent-upload');
  }
  return { ok: true };
}

function describeAttachedFile(ref) {
  const inspected = inspectReferencedElement(ref, 'upload');
  if (!inspected.ok) return inspected;
  const element = globalThis.__FREEDOM_AUTOMATION_ELEMENT_REFERENCES__.refs.get(ref).element;
  const file = element.files?.[0];
  if (!file) return { ok: false, reason: 'selection_not_applied' };
  return {
    ok: true,
    filename: String(file.name || '').slice(0, 255),
    bytes: Number.isSafeInteger(file.size) && file.size >= 0 ? file.size : 0,
    mimeType: String(file.type || '').slice(0, 200),
    fileCount: element.files.length,
  };
}

function selectOptionByValue(ref, value) {
  const inspected = inspectReferencedElement(ref, 'press');
  if (!inspected.ok) return inspected;
  const { element, frameWindow } =
    globalThis.__FREEDOM_AUTOMATION_ELEMENT_REFERENCES__.refs.get(ref);
  if (element.tagName.toLowerCase() !== 'select') return { ok: false, reason: 'unsupported_select' };
  if (element.options.length > 1000) return { ok: false, reason: 'unsupported_select' };
  const values = Array.isArray(value) ? value : [value];
  if (!element.multiple && values.length !== 1) return { ok: false, reason: 'unsupported_select' };
  const options = Array.from(element.options);
  // Reject ambiguous duplicate values and validate the entire change before mutation.
  if (values.some((entry) => options.filter((o) => o.value === entry).length !== 1))
    return { ok: false, reason: 'option_unavailable' };
  const selected = new Set(values);
  if (element.multiple && options.some((o) => o.matches(':disabled') && o.selected !== selected.has(o.value)))
    return { ok: false, reason: 'option_unavailable' };
  if (options.some((o) => selected.has(o.value) && o.matches(':disabled')))
    return { ok: false, reason: 'option_unavailable' };
  if (element.multiple) {
    const setter = Object.getOwnPropertyDescriptor(frameWindow.HTMLOptionElement.prototype, 'selected')?.set;
    if (!setter) return { ok: false, reason: 'unsupported_select' };
    for (const option of options) setter.call(option, selected.has(option.value));
  } else {
    const setter = Object.getOwnPropertyDescriptor(frameWindow.HTMLSelectElement.prototype, 'value')?.set;
    if (!setter) return { ok: false, reason: 'unsupported_select' };
    setter.call(element, values[0]);
  }
  element.dispatchEvent(new frameWindow.Event('input', { bubbles: true }));
  element.dispatchEvent(new frameWindow.Event('change', { bubbles: true }));
  const actual = Array.from(element.selectedOptions, (o) => o.value);
  return actual.length === values.length && actual.every((entry) => selected.has(entry))
    ? { ok: true, trusted: false }
    : { ok: false, reason: 'selection_not_applied' };
}

function prepareTextInsertion(ref, replace) {
  const inspected = inspectReferencedElement(ref, 'type');
  if (!inspected.ok) return inspected;
  const element = globalThis.__FREEDOM_AUTOMATION_ELEMENT_REFERENCES__.refs.get(ref).element;
  if (replace && typeof element.select === 'function') {
    element.select();
  } else if (replace && element.isContentEditable) {
    const selection = element.ownerDocument.defaultView.getSelection();
    const range = element.ownerDocument.createRange();
    range.selectNodeContents(element);
    selection.removeAllRanges();
    selection.addRange(range);
  } else if (!replace && typeof element.setSelectionRange === 'function') {
    const end = String(element.value || '').length;
    element.setSelectionRange(end, end);
  }
  return { ok: true };
}

function referencedElementMatchesState(ref, expectedState) {
  const reference = globalThis.__FREEDOM_AUTOMATION_ELEMENT_REFERENCES__?.refs?.get(ref);
  if (!reference) return { ok: false, reason: 'changed' };
  const { element, frameWindow } = reference;
  try {
    if (element.ownerDocument !== frameWindow.document) return { ok: false, reason: 'changed' };
    if (!element.isConnected) return { ok: true, matched: expectedState === 'hidden' };
    const style = frameWindow.getComputedStyle(element);
    const visible =
      style.display !== 'none' &&
      style.visibility !== 'hidden' &&
      style.opacity !== '0' &&
      element.getClientRects().length > 0;
    if (expectedState === 'hidden') return { ok: true, matched: !visible };
    if (!visible) return { ok: true, matched: false };
    const disabled =
      element.matches(':disabled') || element.getAttribute('aria-disabled') === 'true';
    const role =
      element.getAttribute('role') ||
      {
        BUTTON: 'button',
        A: 'link',
        SELECT: element.multiple || element.size > 1 ? 'listbox' : 'combobox',
      }[element.tagName] ||
      'generic';
    const state = readControlState(element, role);
    return {
      ok: true,
      matched:
        {
          visible: true,
          enabled: !disabled,
          disabled,
          checked: state.checked === true,
          unchecked: state.checked === false,
          expanded: state.expanded === true,
          collapsed: state.expanded === false,
        }[expectedState] === true,
    };
  } catch {
    return { ok: false, reason: 'changed' };
  }
}

function pageContainsText(text) {
  const containsText = (frameWindow) => {
    try {
      if (String(frameWindow.document.body?.innerText || '').includes(text)) return true;
      for (const childFrame of frameWindow.document.querySelectorAll('iframe,frame')) {
        if (childFrame.contentWindow && containsText(childFrame.contentWindow)) return true;
      }
    } catch {
      return false;
    }
    return false;
  };
  return containsText(window);
}

export {

  readElementName,

  readScrollState,

  inspectScrollReference,

  readControlState,

  collectPageSnapshot,

  inspectReferencedElement,

  describeReferencedElement,

  describeFrameReference,

  frameViewport,

  selectOptionByValue,

  prepareTextInsertion,

  referencedElementMatchesState,

  pageContainsText,

  describeAttachedFile,

};
