import { displayHost, isSaveablePage } from "./link.js";
import { savePage } from "./save.js";

const pageTitle = document.querySelector("#page-title");
const pageHost = document.querySelector("#page-host");
const saveButton = document.querySelector("#save-button");
const status = document.querySelector("#status");

let activeTab;
const extensionAPI = globalThis.browser ?? globalThis.chrome;

function showStatus(message, kind = "neutral") {
  status.textContent = message;
  status.dataset.kind = kind;
}

async function loadActivePage() {
  try {
    const [tab] = await extensionAPI.tabs.query({ active: true, currentWindow: true });
    activeTab = tab;

    const canSave = Boolean(tab?.id && isSaveablePage(tab.url));
    pageTitle.textContent = tab?.title?.trim() || "Current page";
    pageHost.textContent = displayHost(tab?.url || "");
    saveButton.disabled = !canSave;

    if (!canSave) {
      showStatus("Open an article or website first.", "error");
    }
  } catch {
    saveButton.disabled = true;
    showStatus("Stower could not read this tab.", "error");
  }
}

saveButton.addEventListener("click", async () => {
  if (!activeTab?.id || !isSaveablePage(activeTab.url)) {
    showStatus("This page cannot be saved.", "error");
    return;
  }

  saveButton.disabled = true;
  saveButton.dataset.saving = "true";
  showStatus("Saving to Stower…");

  try {
    await savePage(extensionAPI, activeTab);
    showStatus("Saved to Stower", "success");
    window.setTimeout(() => window.close(), 450);
  } catch (error) {
    saveButton.disabled = false;
    delete saveButton.dataset.saving;
    showStatus(error?.message || "Stower could not save this page.", "error");
  }
});

loadActivePage();
