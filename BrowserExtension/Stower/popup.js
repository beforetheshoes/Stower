import { displayHost, isSaveablePage, makeStowerLink } from "./link.js";

const pageTitle = document.querySelector("#page-title");
const pageHost = document.querySelector("#page-host");
const saveButton = document.querySelector("#save-button");
const status = document.querySelector("#status");

let activeTab;

function showStatus(message, kind = "neutral") {
  status.textContent = message;
  status.dataset.kind = kind;
}

async function loadActivePage() {
  try {
    const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
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
  showStatus("Opening Stower…");

  try {
    await chrome.tabs.update(activeTab.id, { url: makeStowerLink(activeTab.url) });
    showStatus("Sent to Stower", "success");
    window.setTimeout(() => window.close(), 450);
  } catch {
    saveButton.disabled = false;
    delete saveButton.dataset.saving;
    showStatus("Could not open Stower. Make sure the app is installed.", "error");
  }
});

loadActivePage();
