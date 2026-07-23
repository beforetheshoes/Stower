import assert from "node:assert/strict";
import test from "node:test";

import { NATIVE_APP_ID, savePage } from "../Stower/save.js";

const tab = {
  id: 42,
  url: "https://www.example.com/article?page=2&mode=reader#notes",
};

test("saves through Safari native messaging when the bundled extension is available", async () => {
  const messages = [];
  const updates = [];
  const extensionAPI = {
    runtime: {
      async sendNativeMessage(applicationID, message) {
        messages.push({ applicationID, message });
        return { success: true };
      },
    },
    tabs: {
      async update(...arguments_) {
        updates.push(arguments_);
      },
    },
  };

  const result = await savePage(extensionAPI, tab);

  assert.deepEqual(result, { delivery: "native" });
  assert.deepEqual(messages, [{
    applicationID: NATIVE_APP_ID,
    message: { action: "save", url: tab.url },
  }]);
  assert.deepEqual(updates, []);
});

test("falls back to the Stower app link when native messaging is unavailable", async () => {
  const updates = [];
  const extensionAPI = {
    runtime: {
      async sendNativeMessage() {
        throw new Error("Native host unavailable");
      },
    },
    tabs: {
      async update(...arguments_) {
        updates.push(arguments_);
      },
    },
  };

  const result = await savePage(extensionAPI, tab);

  assert.deepEqual(result, { delivery: "app-link" });
  assert.equal(updates.length, 1);
  assert.equal(updates[0][0], tab.id);
  const link = new URL(updates[0][1].url);
  assert.equal(link.protocol, "stower:");
  assert.equal(link.searchParams.get("url"), tab.url);
});

test("shows a native save failure instead of claiming success", async () => {
  const extensionAPI = {
    runtime: {
      async sendNativeMessage() {
        return { success: false, error: "The shared library is unavailable." };
      },
    },
    tabs: {
      async update() {
        assert.fail("A handled native failure must not navigate the active tab.");
      },
    },
  };

  await assert.rejects(
    savePage(extensionAPI, tab),
    /The shared library is unavailable/,
  );
});

test("rejects non-web pages before contacting the native extension", async () => {
  const extensionAPI = {
    runtime: {
      async sendNativeMessage() {
        assert.fail("Invalid pages must not reach native messaging.");
      },
    },
  };

  await assert.rejects(
    savePage(extensionAPI, { id: 42, url: "safari-extension://settings" }),
    /cannot be saved/,
  );
});
