import { isSaveablePage, makeStowerLink } from "./link.js";

export const NATIVE_APP_ID = "com.ryanleewilliams.stower";

export async function savePage(extensionAPI, tab) {
  if (!tab?.id || !isSaveablePage(tab.url)) {
    throw new TypeError("This page cannot be saved.");
  }

  let response;
  try {
    response = await extensionAPI.runtime.sendNativeMessage(NATIVE_APP_ID, {
      action: "save",
      url: tab.url,
    });
  } catch {
    await extensionAPI.tabs.update(tab.id, { url: makeStowerLink(tab.url) });
    return { delivery: "app-link" };
  }

  if (!response?.success) {
    throw new Error(response?.error || "Stower could not save this page.");
  }

  return { delivery: "native" };
}
