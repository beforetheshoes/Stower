import assert from "node:assert/strict";
import test from "node:test";

import { displayHost, isSaveablePage, makeStowerLink } from "../Stower/link.js";

test("builds an encoded Stower app link without losing query or fragment data", () => {
  const page = "https://www.example.com/article?page=2&mode=reader#notes";
  const link = new URL(makeStowerLink(page));

  assert.equal(link.protocol, "stower:");
  assert.equal(link.hostname, "save");
  assert.equal(link.searchParams.get("url"), page);
});

test("accepts only ordinary web pages", () => {
  assert.equal(isSaveablePage("http://example.com"), true);
  assert.equal(isSaveablePage("https://example.com"), true);
  assert.equal(isSaveablePage("file:///tmp/article"), false);
  assert.equal(isSaveablePage("chrome://extensions"), false);
  assert.equal(isSaveablePage("not a url"), false);
});

test("formats a compact site name", () => {
  assert.equal(displayHost("https://www.goldenhillsoftware.com/blog/"), "goldenhillsoftware.com");
  assert.equal(displayHost("chrome://extensions"), "This page cannot be saved");
});
