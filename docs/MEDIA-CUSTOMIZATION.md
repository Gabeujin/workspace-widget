# Media Customization

Workspace Widget can apply a visual theme and background media to the widget,
and it can show media while the pointer is over an individual shortcut card.
All media settings are stored in the current user's state file.

Only configure content that you trust and have permission to display.
Workspace Widget stores the original local path or URL. Public HTTPS raster
images are additionally copied into a bounded per-user cache before decoding;
local files and local video remain at their configured source. Direct remote
video is intentionally rejected.

## Open appearance settings

Open **Settings > Appearance & media**. Settings has **General** and
**Appearance & media** tabs in both Korean and English; it is one window, not
a separate legacy appearance dialog.

The current presets are:

- **Midnight**
- **Neon**
- **Sakura**
- **Monochrome**
- **Custom**

Each preset controls the accent, panel, card, card-hover, and primary-text
colors. Color fields accept WPF color names or `#AARRGGBB` values. Editing a
preset's values saves the result as **Custom**.

## Supported media

| Source | Background | Shortcut hover |
| --- | --- | --- |
| Local PNG, JPG, JPEG, BMP, ICO | Image | Image |
| Direct HTTPS PNG, JPG, JPEG, BMP, ICO | Image | Image |
| Local GIF | Animated at a fixed frame interval | Animated at a fixed frame interval |
| Direct HTTPS GIF | Not supported for animation | Not supported for animation |
| Local MP4, M4V, WMV, AVI, MOV | Looping video | Looping video while hovered |
| Public HTTPS MP4, M4V, WMV, AVI, MOV | Rejected | Rejected |
| YouTube watch, short, embed, or `youtu.be` URL | Remote poster image | Privacy-enhanced embedded playback with WebView2, otherwise a poster |

Automatic type detection uses the URL or file extension. A direct HTTPS static
image should therefore expose one of the supported image extensions in its URL
path. HTML pages, arbitrary web pages, `data:` URLs, plain HTTP media URLs, and
direct remote video streams are not accepted as media sources.

Supported video file extensions do not guarantee codec support. Playback uses
Windows media components, so the codecs installed on the device and the remote
server's streaming behavior still determine whether a video plays.

## Background media

In **Appearance & media**:

1. enter a local file path, public HTTPS static-image URL, or YouTube URL, or
   select **Browse...** for a local file;
2. choose the background-media opacity from 5 to 100 percent;
3. choose whether background video is muted; and
4. select **Apply**.

The Appearance & media page is a draft. **Apply** validates and saves its
theme, colors, media, opacity, and mute settings together. **Cancel**, closing
the Settings window, or switching tabs does not apply unfinished appearance
edits. Widget opacity is a single shared setting across full and MIN UI modes;
it is configured on the General tab.

Select **Clear media** and then **Apply** to return to the theme-only
background.

Background image and video are drawn under a tinted panel layer so shortcut
labels remain readable.

### Background images

Local images are loaded as bitmap content. Public HTTPS images and YouTube
posters are downloaded with a 10-second timeout and a 10 MB response limit,
checked across at most three public-HTTPS redirects, validated by content type
and decoded dimensions, and then read from
`%LOCALAPPDATA%\WorkspaceServiceWidget\MediaCache`. Raster input is limited to
8192 pixels per side and 32 megapixels. Local image and GIF containers are also
limited to 64 MB; GIFs are limited to 240 frames and a bounded aggregate pixel
budget. Each managed IconCache or MediaCache directory accepts at most 128 MB
of content and fails closed instead of silently deleting older files.

### Background GIFs

Animated GIF backgrounds must be local files. Frames are decoded into memory
and advanced at a fixed 90 ms interval. The original per-frame timing is not
preserved, and a large or high-resolution GIF can use substantial memory.

### Background video

Background video loops when playback reaches the end. When unmuted, the current
volume is limited to 35 percent. Video can consume CPU, GPU, network bandwidth,
and battery power while the widget is visible.

### YouTube background

A YouTube background displays the video's `hqdefault.jpg` poster from
`i.ytimg.com`. It does not play the YouTube video in the background.

Use an individual shortcut's hover media when inline YouTube playback is
required.

## Shortcut hover media

Right-click a shortcut, select **Edit**, and enter a source in
**Hover media (optional)**. The edit dialog also includes a mute option for
hover video.

The preview appears only in the full layout while the pointer is over the card.
It stops when the pointer leaves the card. MIN UI does not display hover-media
previews.

### Custom shortcut icons

The shortcut edit dialog accepts a local icon image, an image from the Windows
clipboard, or a public HTTPS image URL. Local formats are PNG, JPG, JPEG, BMP,
ICO, and GIF. Remote formats are PNG, JPG, JPEG, BMP, ICO, GIF, and static SVG.
A GIF custom icon uses its first frame as a static icon.

Select **Paste image** after copying an image or screenshot. The clipboard
bitmap is normalized to a transparent 256 x 256 PNG card asset in
`%LOCALAPPDATA%\WorkspaceServiceWidget\IconCache`, displayed in the same small
preview, and requires **I confirm this preview is the icon I want** before
**Save** is enabled. Clipboard input is limited to 8192 pixels per side,
32 megapixels, and a 10 MB normalized PNG.

HTTPS icons are downloaded with a 10-second timeout and a 2 MB response limit.
The response must declare a supported image content type, every redirect must
remain on a public HTTPS address, and raster data must decode successfully.
Raster input is also limited to 8192 pixels per side and 32 megapixels, then
aspect-fit into the same transparent 256 x 256 card asset used by shortcuts.
SVG icons are rejected when they contain scripts, event handlers, embedded
documents, style blocks, or external resource references. A verified static SVG
is rendered locally and normalized into that same card format.

After the URL is entered, the edit dialog automatically loads a small preview.
The user must inspect that preview and select **I confirm this preview is the
icon I want** before **Save** is enabled. The verified result is cached below
`%LOCALAPPDATA%\WorkspaceServiceWidget\IconCache`; the source URL remains in
the registration for attribution and later review.

When an existing registration is edited, its previously verified local card
copy is loaded before the signed URL is evaluated. This means a card remains
usable after its source URL expires. Select **Retry preview** to explicitly
download and validate the source again; an expired URL or network failure does
not replace or discard the existing local copy.

Signed CDN URLs such as Flaticon SVG addresses containing
`token=exp=...~hmac=...` work only until the embedded Unix expiration time.
Workspace Widget displays that time in the preview and asks for a fresh copied
address after expiry only when no verified local copy exists. A browser may
still show an expired address from its own cache, which does not make the URL
reusable by the widget.

If the custom icon cannot load, the card falls back to the target's Windows
shell icon or its normal glyph.

### Hover images and GIFs

Images appear in the preview surface. Animated GIF hover media must be a local
file and uses the same fixed 90 ms frame interval as the background.

### Hover video

Local video plays while the card is hovered and loops when it ends. The
per-item mute preference applies to normal video. Unmuted hover video uses a
maximum volume of 35 percent. Direct remote video is rejected because the
Windows media pipeline cannot share the widget's bounded downloader and public
address checks.

### YouTube hover playback

When the Microsoft Edge WebView2 Evergreen Runtime is available, Workspace
Widget creates a non-interactive WebView2 control and navigates only to:

```text
https://www.youtube-nocookie.com/embed/<video-id>
```

Playback requests autoplay, mute, no controls, looping, and inline playback.
YouTube hover playback is always muted regardless of the normal video mute
checkbox. The desktop WebView2 request includes a stable HTTPS `Referer`, plus
`origin` and `widget_referrer` player parameters. The same `Referer` is
reapplied to subsequent YouTube WebView2 resource requests so redirects do not
drop the desktop client identity and trigger player error 153.

The WebView2 control disables its default context menu, developer tools, status
bar, zoom controls, web messages, host objects, password storage, and autofill.
Popup windows and downloads are cancelled, permission requests are denied, and
top-level navigation is parsed and restricted to `about:blank` or the exact
`https://www.youtube-nocookie.com/embed/<video-id>` route.

If the WebView2 assemblies or control are unavailable when the preview is
created, the hover preview falls back to the YouTube poster and labels the
preview with an instruction to install WebView2. If control creation succeeds
but WebView2 later fails during asynchronous Runtime initialization, the
current build logs the error and returns to the poster or themed fallback.

The release package includes the WebView2 SDK assemblies and native loader. It
does not download or install the Microsoft Edge WebView2 Evergreen Runtime.
Enterprise administrators should service that runtime through their normal
Microsoft Edge management process.

WebView2 user data is stored under:

```text
%LOCALAPPDATA%\WorkspaceServiceWidget\WebView2
```

WebView2 is launched with a 32 MB disk-cache target. Its profile is separate
from the app-managed IconCache and MediaCache budgets and remains subject to the
Evergreen Runtime's own servicing and storage behavior.

## State fields

Background appearance is stored below `window.appearance`:

```json
{
  "theme": "Midnight",
  "accentColor": "#FF3E8BFF",
  "panelColor": "#EE09162B",
  "cardColor": "#E80F203B",
  "cardHoverColor": "#F2162F56",
  "textColor": "#FFF6F9FF",
  "backgroundMedia": "",
  "backgroundMediaKind": "auto",
  "backgroundMediaOpacity": 0.42,
  "backgroundVideoMuted": true
}
```

Each shortcut can store:

```json
{
  "customIcon": "",
  "hoverMedia": "",
  "hoverMediaKind": "auto",
  "hoverMediaMuted": true
}
```

The UI currently saves an automatically detected media kind. Manual editing of
the state file is not required and should not be performed while the widget is
running.

## Trust, privacy, and copyright

### Trusted content

Local media is parsed by Windows imaging or media components. Remote media
causes outbound network requests and is decoded by Windows or WebView2. Use
only trusted files and trusted HTTPS origins.

Remote raster images must resolve to public addresses. Every handled redirect
is checked again, downloads are bounded to 10 MB, response types are allowlisted,
and decoded dimensions are capped before the local cache is rendered. Direct
remote video is rejected because Windows streaming would create a second
network path outside that downloader. Local video still requires a trusted file
because codec support and stream behavior are controlled by Windows and the
server.

Do not configure:

- untrusted downloads;
- media from an origin that can replace the file without review;
- sensitive intranet URLs that should not be polled or displayed by a desktop
  process; or
- paths that expose confidential project or customer information in shared
  screenshots.

### Privacy

Direct HTTPS media contacts the configured server. YouTube posters contact
`i.ytimg.com`, and YouTube hover playback contacts
`youtube-nocookie.com` and related YouTube delivery infrastructure. Those
services can observe connection metadata such as the device's public IP
address.

The privacy-enhanced embed domain reduces normal YouTube embedding behavior but
does not make playback offline or eliminate all network processing.

### Copyright and distribution

Workspace Widget does not grant a license to media selected by a user. Confirm
that you have the right to display, stream, copy, screenshot, and redistribute
each configured asset.

Do not add third-party logos, character artwork, game footage, advertising
assets, or YouTube content to a public release package unless the applicable
license explicitly permits redistribution. Prefer original artwork or assets
with documented redistribution terms, and preserve required attribution.

## Troubleshooting media

### A public HTTPS image is rejected

- Confirm the URL begins with `https://`.
- Confirm its hostname resolves only to public addresses.
- Confirm its URL path ends in a supported extension.
- Use the direct static-image URL, not an HTML viewer or sharing page.

### A GIF is accepted but does not animate

Remote GIF animation is not supported. Save an authorized copy as a local
`.gif` file and select that file. Confirm the local file is readable.

### A video is blank or reports playback failure

- Test the file in a Windows media application on the same device.
- Try MP4 video encoded with codecs supported by the organization's Windows
  image.
- Direct HTTPS video is intentionally unsupported. Download trusted video to a
  local file or use a supported YouTube URL.
- Review `runtime.log` for `MediaFailed` details. An asynchronous media failure
  is logged and the current preview returns to its poster or themed fallback.

### YouTube shows a poster instead of video

- Confirm the URL contains a valid 11-character YouTube video identifier.
- Normal share links in the form
  `https://youtu.be/<11-character-video-id>` are accepted directly; converting
  them to an `/embed/` URL is not required.
- Confirm the WebView2 Evergreen Runtime is installed and allowed by policy.
- Confirm outbound access to the privacy-enhanced embed and thumbnail hosts.
- Review `runtime.log` for WebView2 initialization errors.

### An HTTPS custom icon cannot be saved

- Wait for the automatic preview check to finish.
- Confirm that the response is a public HTTPS image no larger than 2 MB.
- For SVG, use a self-contained static icon without scripts, event handlers,
  embedded HTML, or external resources.
- Select **I confirm this preview is the icon I want** after visually checking
  the rendered icon. **Save** stays disabled until both checks succeed.
- Signed or tokenized CDN URLs can expire. The cached icon remains usable, but
  explicitly refreshing it later may require a new image URL.
- Prefer a stable CDN image address when the provider offers one. For example,
  Flaticon PNG CDN links are usually longer-lived than temporary SVG links
  containing `token=exp=...`.

### Media reduces responsiveness

Use smaller dimensions and shorter files. Prefer a static image for long-running
backgrounds. Large GIFs are fully decoded into memory, and video continues to
consume resources while it is displayed.
