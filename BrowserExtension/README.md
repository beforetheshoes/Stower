# Save to Stower for Safari

The Safari Web Extension is bundled with Stower on iPhone, iPad, and Mac. It
saves the active HTTP or HTTPS page directly into Stower's shared library and
requests access only to the tab you explicitly choose from the toolbar.

## Enable in Safari

1. Install and launch Stower.
2. On Mac, open **Safari > Settings > Extensions** and enable
   **Save to Stower**. Add it to the Safari toolbar if Safari does not add it
   automatically.
3. On iPhone or iPad, open Safari's page menu, choose **Extensions**, and enable
   **Save to Stower**.

Open an article, click the Stower raccoon, then choose **Save to Stower**.
The page is added to Stower's unread queue without replacing the current tab.
The shortcut to open the extension is Control-Shift-S on macOS.

The same web-extension resources remain compatible with Chromium browsers. If
native Safari messaging is unavailable, the extension falls back to Stower's
validated `stower://` app link.

## Test

From the repository root:

```sh
npm test --prefix BrowserExtension
```
