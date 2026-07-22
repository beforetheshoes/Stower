export const STOWER_SCHEME = "stower";

export function isSaveablePage(value) {
  try {
    const url = new URL(value);
    return url.protocol === "http:" || url.protocol === "https:";
  } catch {
    return false;
  }
}

export function makeStowerLink(value, scheme = STOWER_SCHEME) {
  if (!isSaveablePage(value)) {
    throw new TypeError("Stower can save only HTTP or HTTPS pages.");
  }

  const target = new URL(value);
  const link = new URL(`${scheme}://save`);
  link.searchParams.set("url", target.href);
  return link.href;
}

export function displayHost(value) {
  if (!isSaveablePage(value)) {
    return "This page cannot be saved";
  }
  return new URL(value).hostname.replace(/^www\./, "");
}
