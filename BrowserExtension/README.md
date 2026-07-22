# Save to Stower for Helium

This Manifest V3 Chromium extension saves the active HTTP or HTTPS page to the
installed Stower app. It requests only `activeTab`, which grants temporary
access to the page you explicitly choose from the toolbar.

## Install in Helium

1. Install and launch a Release build of Stower at least once so macOS
   registers the `stower://` app link.
2. Open `chrome://extensions` in Helium.
3. Turn on **Developer mode**.
4. Choose **Load unpacked** and select the `BrowserExtension/Stower` folder.
5. Pin **Save to Stower** to the toolbar.

Open an article, click the Stower raccoon, then choose **Save to Stower**.
Stower opens, captures the page, and leaves it in the unread queue. The shortcut
to open the extension is Control-Shift-S on macOS.

Debug builds register `stower-dev://` to remain isolated from TestFlight and
App Store builds. The packaged extension intentionally targets the production
`stower://` scheme.

## Test

From the repository root:

```sh
npm test --prefix BrowserExtension
```
