import assert from "node:assert/strict";
import { existsSync, readFileSync } from "node:fs";
import test from "node:test";
import { fileURLToPath } from "node:url";

const extensionRoot = fileURLToPath(new URL("../Stower/", import.meta.url));
const manifest = JSON.parse(readFileSync(`${extensionRoot}/manifest.json`, "utf8"));

test("uses Manifest V3 and requests only temporary access to the active tab", () => {
  assert.equal(manifest.manifest_version, 3);
  assert.deepEqual(manifest.permissions, ["activeTab"]);
  assert.equal(manifest.host_permissions, undefined);
  assert.equal(manifest.content_scripts, undefined);
});

test("references files that are included in the unpacked extension", () => {
  const referencedFiles = [
    manifest.action.default_popup,
    ...Object.values(manifest.action.default_icon),
    ...Object.values(manifest.icons),
  ];

  for (const path of new Set(referencedFiles)) {
    assert.equal(existsSync(`${extensionRoot}/${path}`), true, `${path} is missing`);
  }
});
