# Workspace Widget Microsoft Store listing kit

- Prepared: 2026-07-30
- Target version: 0.1.0
- Package type: MSIX, Windows 11 x64
- Status: copy-ready except for Partner Center identity, independent-device
test results, package upload, and certification results

This document is the copy source for the first Microsoft Store submission.
Do not upload a legacy installer or an unsigned development MSIX as a public
download.

## Stable public URLs

| Field | Value |
| --- | --- |
| Product website | <https://gabeujin.github.io/workspace-widget/> |
| Privacy policy | <https://gabeujin.github.io/workspace-widget/privacy/> |
| Support | <https://gabeujin.github.io/workspace-widget/support/> |
| Public source | <https://github.com/Gabeujin/workspace-widget> |
| Security reporting | <https://github.com/Gabeujin/workspace-widget/security/advisories/new> |
| License | MIT |

All three `gabeujin.github.io` URLs returned HTTP 200 over HTTPS on
2026-07-30. Verify them again immediately before submitting.

## Partner Center product setup

| Field | Proposed value |
| --- | --- |
| Product type | MSIX or PWA app |
| Reserved product name | Workspace Widget |
| Primary category | Productivity |
| Secondary category | Developer tools |
| Secondary subcategory, if offered | Utilities |
| Pricing | Free |
| Markets | All markets allowed by the account and Microsoft policy |
| Supported device family | Windows Desktop |
| Architecture | x64 |
| Minimum OS | Windows 11, build 22000 |
| Generative AI declaration | No — the app does not include or call a generative AI feature |
| Advertising | None |
| In-app purchases | None |
| Account or sign-in | None |

The first submission must complete the IARC questionnaire in Partner Center.
Do not manually choose a desired rating or copy a rating from this draft.

## English listing (`en-US`)

### Product name

Workspace Widget

### Short description

Launch apps, folders, URLs, and health-aware local services from one movable
Windows 11 workspace—without an account, advertising, or developer telemetry.

### Full description

Workspace Widget brings apps, files, folders, web links, and local development
services into one movable Windows 11 workspace.

Drop or register Windows shortcuts, executables, files, folders, and HTTP or
HTTPS links. Explicit URL ports are shown on the card, and an optional health
endpoint can be checked every 30 seconds so you can see when a local service is
ready.

For a trusted offline service, you can configure a local JavaScript entry point
or package script. When the service is offline, Workspace Widget starts the
target with its bundled Node.js runtime, waits for the configured health
endpoint, and opens the URL when ready. It never installs project dependencies
and runs only the target you selected with your signed-in user permissions.

Use Always on top for a persistent launcher or switch to the 96 px MIN UI rail
and snap it to a screen edge. Adjust opacity, hover brightness, themes, colors,
and optional local or validated HTTPS media. Hide the app to the notification
area, restore it from the tray, and control Start with Windows from the app or
Windows Startup Apps settings.

Workspace Widget is local-first. It has no developer-operated account,
advertising, analytics, or telemetry service. Network requests occur only for
health checks, links, and media that you configure or invoke. Review the public
privacy and security documentation before configuring executable targets or
remote media.

Requires 64-bit Windows 11. Microsoft Edge WebView2 is used for optional
privacy-enhanced YouTube hover previews and is normally included with
Windows 11.

### Product features

Enter each line as a separate feature. Partner Center adds the bullets.

1. Launch apps, files, folders, Windows shortcuts, and web URLs
2. Resolve `.lnk` targets with their arguments, working directory, and icon
3. Display explicit URL ports and optional health-check status
4. Start trusted offline JavaScript or package scripts with bundled Node.js
5. Wait for a local service to become healthy before opening it
6. Use a 96 px edge-snapped MIN UI icon rail
7. Control Always on top, opacity, hover brightness, and smooth scrolling
8. Choose built-in themes, custom colors, and local or validated HTTPS media
9. Hide to the tray and control Start with Windows
10. Keep configuration local with no account, advertising, or developer telemetry

### Supplemental fields

| Field | Value |
| --- | --- |
| Short title | Workspace Widget |
| Sort title | Workspace Widget |
| Search terms, if shown | launcher, productivity, local app, widget, shortcut, health check, Node.js |
| What's new | Leave blank for the first submission |
| Minimum hardware | 64-bit processor; keyboard or pointing device |
| Recommended hardware | 1366 × 768 or higher display |

## Korean listing (`ko-KR`)

### 제품 이름

Workspace Widget

### 간단한 설명

계정, 광고, 개발자 텔레메트리 없이 앱, 폴더, URL과 Health-aware 로컬
서비스를 하나의 이동 가능한 Windows 11 작업 공간에서 실행하세요.

### 전체 설명

Workspace Widget은 앱, 파일, 폴더, 웹 링크와 로컬 개발 서비스를 하나의
이동 가능한 Windows 11 작업 공간으로 모아주는 런처입니다.

Windows 바로가기, 실행 파일, 파일, 폴더와 HTTP/HTTPS 링크를 끌어 놓거나
직접 등록하세요. URL에 명시된 포트를 카드에 표시하고, 선택적 Health
엔드포인트를 30초마다 확인해 로컬 서비스가 준비되었는지 알려줍니다.

신뢰하는 오프라인 서비스에는 로컬 JavaScript 진입점 또는 패키지
스크립트를 지정할 수 있습니다. 서비스가 오프라인이면 번들 Node.js
런타임으로 사용자가 선택한 대상을 실행하고, 구성한 Health 엔드포인트가
준비된 뒤 URL을 엽니다. 프로젝트 의존성을 자동으로 설치하지 않으며,
로그인한 사용자의 기존 권한으로 사용자가 직접 선택한 대상만 실행합니다.

Always on top으로 런처를 항상 표시하거나 96px MIN UI 아이콘 레일로
축소해 화면 가장자리에 붙여두세요. 불투명도, Hover brightness, 테마,
색상과 선택적 로컬 또는 검증된 HTTPS 미디어를 설정할 수 있습니다.
알림 영역으로 숨겼다가 트레이에서 다시 열고, 앱 또는 Windows 시작
프로그램 설정에서 Start with Windows를 제어할 수 있습니다.

Workspace Widget은 로컬 우선 앱입니다. 개발자가 운영하는 계정, 광고,
분석 또는 텔레메트리 서비스가 없습니다. 네트워크 요청은 사용자가
설정하거나 실행한 Health 확인, 링크와 미디어 기능에 한정됩니다. 실행
대상이나 원격 미디어를 구성하기 전에 공개 개인정보 및 보안 문서를
확인하세요.

64비트 Windows 11이 필요합니다. 선택적 YouTube Hover 미리보기에는
개인정보 보호 강화 재생을 위해 Microsoft Edge WebView2를 사용하며,
일반적으로 Windows 11에 포함되어 있습니다.

### 제품 기능

각 줄을 별도 기능으로 입력합니다. Partner Center가 글머리표를 붙입니다.

1. 앱, 파일, 폴더, Windows 바로가기와 웹 URL 실행
2. `.lnk`의 실제 대상, 인수, 작업 디렉터리와 아이콘 확인
3. URL 포트와 선택적 Health 상태 표시
4. 번들 Node.js로 신뢰하는 오프라인 스크립트 또는 패키지 시작
5. 로컬 서비스가 준비된 뒤 URL 자동 실행
6. 화면 가장자리에 붙는 96px MIN UI 아이콘 레일
7. Always on top, 불투명도, Hover brightness와 부드러운 스크롤
8. 내장 테마, 사용자 색상, 로컬 또는 검증된 HTTPS 미디어
9. 트레이 숨기기와 Windows 시작 프로그램 제어
10. 계정, 광고, 개발자 텔레메트리 없는 로컬 구성

### 보조 필드

| 필드 | 값 |
| --- | --- |
| 짧은 제목 | Workspace Widget |
| 정렬 제목 | Workspace Widget |
| 검색어 필드가 표시될 경우 | 런처, 생산성, 로컬 앱, 위젯, 바로가기, Health check, Node.js |
| 새로운 기능 | 첫 제출에서는 비워 둠 |
| 최소 하드웨어 | 64비트 프로세서, 키보드 또는 포인팅 장치 |
| 권장 하드웨어 | 1366 × 768 이상 디스플레이 |

## Screenshot upload map

All final screenshots are opaque PNG files at 1366 × 768. Upload them as
Desktop screenshots in this order.

| Order | File | English caption | Korean caption |
| --- | --- | --- | --- |
| 1 | `docs/media/store/store-01-overview.png` | Launch apps, folders, URLs, and local services from one workspace. | 앱, 폴더, URL과 로컬 서비스를 한 화면에서 실행하세요. |
| 2 | `docs/media/store/store-02-settings.png` | Tune startup, always-on-top, MIN UI, and appearance to fit your workflow. | 시작 프로그램, 항상 위, MIN UI와 화면 스타일을 원하는 방식으로 설정하세요. |
| 3 | `docs/media/store/store-03-add-service.png` | Register a URL and health API, then start an offline local service with bundled Node.js. | URL과 Health API를 등록하고 오프라인 로컬 서비스를 번들 Node.js로 시작하세요. |
| 4 | `docs/media/store/store-04-context-menu.png` | Edit and organize shortcuts from the context menu. | 우클릭 메뉴로 바로가기를 편집하고 순서를 정리하세요. |

Optional Store listing icon source:

- `docs/media/brand/workspace-widget-store-icon-300.png` — 300 × 300 PNG

MSIX package tile assets are generated separately by
`scripts/Build-WorkspaceWidgetMsix.ps1` from the canonical application logo.

## Privacy and property declarations

Use the conservative declaration because user-configured network requests can
transmit the device's ordinary connection metadata to the selected endpoint or
media provider.

| Question area | Draft answer |
| --- | --- |
| Accesses, collects, or transmits personal information | Yes — provide the published privacy URL |
| Developer-operated analytics or telemetry | No |
| Advertising identifiers or advertising | No |
| Account creation or sign-in | No |
| Location, contacts, camera, microphone, or Bluetooth access | No |
| User-configured Internet access | Yes — health URLs, web links, HTTPS media, and optional YouTube preview |
| Generative AI features | No |
| Purchases or subscriptions | No |

Partner Center's wording is authoritative. Re-read each live question and
adjust only when the exact certified package behavior requires it.

## IARC age-rating answer draft

- Category: utility/productivity application.
- No violence, sexual content, profanity, controlled substances, gambling, or
  simulated gambling supplied by the app.
- No advertising, purchases, social network, chat, or user-to-user sharing.
- The app can open user-selected external web content in the default browser
  and can display a user-selected YouTube preview. Answer Internet/external
  content questions accurately instead of assuming the lowest rating.
- The app does not generate content with AI.

Save the final IARC result and questionnaire receipt with the release evidence.

## `runFullTrust` justification

Paste this into Submission options or certification notes:

> Workspace Widget is a user-controlled desktop launcher. It opens local apps,
> files, folders, and URLs selected by the user and can start user-selected
> local Node.js projects under the signed-in user's existing permissions. It
> uses full-trust desktop access to resolve Windows shortcuts, launch selected
> local targets, manage its tray window, and integrate with the package-declared
> Windows startup task. It does not elevate, install a service or driver, run as
> SYSTEM, install project dependencies, or execute a target the user did not
> configure.

## Certification notes

> Workspace Widget requires no account or sign-in. Start with Windows is
> disabled by default. To exercise it, launch the app, open Settings, enable
> Start with Windows, then confirm the entry in Windows Settings > Apps >
> Startup. The app may launch local files, applications, folders, URLs, or
> scripts only after the user explicitly adds them. A health URL is optional
> and is polled only for the registered service. The package includes Node.js
> solely for a user-configured local service; it does not download code or
> install dependencies. Select Hide to tray to test notification-area restore,
> and use tray right-click > Exit for complete process exit.

## Partner Center identity resume block

After account approval and product-name reservation, open **Product management
> Product identity** and copy the exact values below. Do not invent or
normalize them.

```json
{
  "packageIdentityName": "<Package/Identity/Name>",
  "publisher": "<Package/Identity/Publisher>",
  "publisherDisplayName": "<Package/Properties/PublisherDisplayName>"
}
```

Also archive:

- Store ID;
- Package Family Name;
- direct Store listing URL;
- account/publisher display name;
- exact package version uploaded.

## First-submission sequence

1. Reserve **Workspace Widget** as an MSIX or PWA app.
2. Copy the three exact package-manifest identity values.
3. Build from a clean reviewed commit with `-StoreSubmission`.
4. Run the independent Store-candidate verifier.
5. Complete the independent Windows 11 lifecycle checklist.
6. Run the current Windows App Certification Kit against the exact candidate.
7. Upload the unsigned producer MSIX to Partner Center.
8. Complete Properties, IARC, Store listings, Submission options, and
   certification notes.
9. Review the package analysis shown by Partner Center.
10. Submit for certification and treat only the resulting Store-signed package
    as the supported public binary.

## Official references

- [Get started with Microsoft Store](https://learn.microsoft.com/windows/apps/publish/get-started)
- [Add and edit Store listing information](https://learn.microsoft.com/windows/apps/publish/publish-your-app/msix/add-and-edit-store-listing-info)
- [Screenshots and images](https://learn.microsoft.com/windows/apps/publish/publish-your-app/pwa/screenshots-and-images)
- [Enter app properties](https://learn.microsoft.com/windows/apps/publish/publish-your-app/msix/enter-app-properties)
- [Generate age ratings](https://learn.microsoft.com/windows/apps/publish/publish-your-app/msix/age-ratings)
- [View product identity details](https://learn.microsoft.com/windows/apps/publish/view-app-identity-details)
- [Windows App Certification Kit](https://learn.microsoft.com/windows/uwp/debug-test-perf/windows-app-certification-kit)
- [Sign an MSIX package](https://learn.microsoft.com/windows/msix/package/signing-package-overview)
