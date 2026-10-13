# 06 - Safari extensions vs. injected CSS for YouTube recommendation hooks

Research date: 2026-10-12.

## 1. Installed extensions

A typical Safari setup runs content blockers and userscript managers, and a userscript manager can run custom JavaScript on YouTube. The approach below does not depend on which extensions are installed.

## 2. Options for scheduled on/off of Safari extensions

Rating scale: reliability (high / medium / low), and size of code needed.

### (a) Edit Safari's extension plist

Not viable. The plist sits inside the Safari sandbox container, is TCC-protected on the machine tested, and Safari caches extension state in memory and rewrites the file on quit. Expect the change to be overwritten or ignored. Reliability: low. Code: small, but needs Full Disk Access for the editing process and Safari quit/relaunch on each change. Not recommended.

### (b) Safari Profiles and Focus Filters

Apple's Mac Help documents a Safari Focus filter with a Tab Group (per Focus, under Focus Filters, Add Filter, Safari, then Filter Type Tab Group). Source: Apple Mac Help, `support.apple.com/guide/mac-help/mchl613dc43f/mac`. The filter switches the visible Tab Group, not extensions. Extensions are not per-profile or per-tab-group toggles in the documented Focus filter. So a Focus filter cannot disable an extension.

Running a shortcut from a Focus on Mac is unreliable. A MacRumors user (Feb 2024) reported that Shortcuts cannot be run via an automation on macOS, which is a user report and may be outdated. The Safari "Open Tab Group" action is reported missing on macOS. Reliability: low for toggling extensions. Code: none, but gives no extension control.

### (c) UI scripting Safari Settings > Extensions via System Events

Works in principle with Accessibility permission for the controlling app, but it is fragile (layout and label changes break it) and it needs the Safari window to be frontmost. Reliability: low to medium. Code: about 40 to 80 lines of AppleScript plus Accessibility grant. Not recommended.

### (d) `pluginkit -e use` / `-e ignore`

`pluginkit -e use -i <id>` and `-e ignore -i <id>` change election state for an extension bundle. This is the most direct system-level switch. Caveats: it was not run in this review, so it may require a running Safari restart, and whether Safari honors the election change without a relaunch is not verified here. Reliability: medium, untested. Code: a launchd job calling `pluginkit` at 09:00 and 18:00, roughly 10 lines of shell. Risk: it disables the whole extension, including SponsorBlock and DeArrow, not just the YouTube hooks.

Ranking: (d) is the cheapest to try, (b) is documented but does not toggle extensions, (c) and (a) are not recommended.

## 3. Recommended approach: scheduled CSS/JS injection, no extension

The app injects a `<style>` element into YouTube tabs during work hours and removes it outside work hours. This does not depend on any Safari extension state, so it is independent of TCC and extension election.

### Does injected `<style>` survive YouTube's SPA navigation?

Yes, in practice. YouTube is a single-page app and does not rebuild `<head>` on navigation, so a `<style id="...">` appended to `document.head` persists across home, watch, and search navigation. Evidence: Unhook NG injects its stylesheet into `document.head` once and re-applies it only on `yt-navigate-start` (see section 4 below). It does not depend on `yt-navigate-finish`, which shows that the style element survives navigation. The inject step should still be idempotent (check for an existing element by id) so repeated runs do not stack.

### Safari setup (one-time, user action)

Safari > Settings > Advanced > tick "Show features for web developers" (or "Show Develop menu in menu bar" in newer builds). Then Develop > Allow JavaScript from Apple Events. Without this, `do JavaScript` fails with an error. Source: from knowledge of Safari's AppleScript support, not re-verified in this review. Test once before relying on it.

### Chrome setup (one-time, user action)

View > Developer > Allow JavaScript from Apple Events. Chrome's AppleScript `execute javascript` requires this.

### AppleScript sketch (Safari)

```applescript
tell application "Safari"
  repeat with w in windows
    repeat with t in tabs of w
      if URL of t contains "youtube.com" then
        do JavaScript "(function(){var id='focus-hide';var s=document.getElementById(id);if(!s){s=document.createElement('style');s.id=id;document.head.appendChild(s);}s.textContent=`__CSS__`;})();" in t
      end if
    end repeat
  end repeat
end tell
```

Outside work hours, the same loop runs with `s.remove()` in place of setting `textContent`. A launchd agent (StartCalendarInterval at the work-hours boundaries) runs the script. Re-run it also on a timer (e.g. every 5 minutes) so new tabs get the style.

## 4. CSS selector list

Sources:

- Unhook NG, `https://github.com/TheArchons/unhookng` (file `unhook.js`, GPL v3). The element names below are YouTube's own, as listed in `unhook.js`; the app's list in Sources/Focus/Activity.swift is a subset of them.
- Userstyles and extension listings (Hide YouTube Thumbnails, Remove YouTube Thumbnails userstyle) for the thumbnail rules. Sourced from search result pages, not from reading their code.
- Items marked "unverified" are not in any source read and must be checked in the live DOM.

Home feed (only on `/`):

```css
ytd-rich-grid-renderer { display: none !important; }
```

Subscriptions feed (`/feed/subscriptions`): same selector, Unhook NG applies it only on that path.

Related / Up-next sidebar:

```css
#secondary { display: none !important; }
#related { display: none !important; }
```

Shorts shelves and tabs:

```css
a#endpoint[title="Shorts"], ytd-shorts, grid-shelf-view-model, ytd-rich-shelf-renderer { display: none !important; }
```

End-screen cards:

```css
.ytp-fullscreen-grid, .ytp-ce-element, .ytp-endscreen-content { display: none !important; }
```

`.ytp-endscreen-content` comes from the original brief and is not in Unhook NG's list. Keep it as a harmless extra, verify in DevTools.

Video thumbnails (search results and watch-page suggestions must still show. Do not hide the search results container):

```css
ytd-watch-next-secondary-results-renderer { display: none !important; }
```

This is the selector from the original brief and is not in Unhook NG. Unverified, check in DevTools. Thumbnails in the home grid are already removed by the `ytd-rich-grid-renderer` rule above. For thumbnails on the watch page sidebar, `#secondary` covers it.

Autoplay: Unhook NG has no autoplay rule. Unverified options:

- YouTube's own autoplay toggle is `.ytp-autonav-toggle-button` (from memory, unverified). A script could click it when `aria-checked` is `"true"`, or set `localStorage` if YouTube reads a key for it (unverified).
- Hiding the end screen (rules above) removes the autoplay "next video" countdown in most cases.

Comments: skipped, from the original brief.

Sidebar profile photos: `#author-thumbnail` (Unhook NG `hideProfilePhotos`). Not needed.

## 5. Reliability summary

- Scheduled injection (section 3): high once the Safari/Chrome Apple Events setting is on. Code: about 30 lines AppleScript plus a launchd plist. Risk: YouTube renames elements; selectors above may go stale.
- Extension election (2d): medium, untested here, disables whole extensions.
- Plist edit (2a): low, blocked by TCC.
- Focus filters (2b): documented for Tab Groups only, cannot toggle extensions.
- UI scripting (2c): low to medium, fragile.

## 6. Open items

- Confirm `pluginkit -e use/ignore` behavior with a test on a non-critical extension (not run in this review).
- Verify the `ytd-watch-next-secondary-results-renderer` and autoplay selectors in the live DOM.
- Grant Full Disk Access only if option (a) is pursued (not recommended).
