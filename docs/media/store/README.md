# Microsoft Store Screenshot Set

This directory contains the public-safe desktop screenshots prepared for the
Workspace Widget Microsoft Store listing.

## Submission files

| Order | File | Scenario | Dimensions | SHA-256 |
| --- | --- | --- | --- | --- |
| 1 | `store-01-overview.png` | Main workspace with URLs, local apps, a folder, and a healthy sample service | 1366 × 768 | `087965E1049094B152CD80E5BE869DA4FBF76E7F42F2C6EE3F6E7BF5720F1419` |
| 2 | `store-02-settings.png` | Settings for startup, always-on-top, MIN UI, and appearance | 1366 × 768 | `4818A667E3C16F24D23E92D5C4DCA7749BA5D7DEFB6201D6EFE55C33AAA6AC8C` |
| 3 | `store-03-add-service.png` | Adding a local service with URL, health endpoint, and bundled Node target | 1366 × 768 | `0856846DB7F9917E64AB81133B4AA40CF037E4D8378F339BC53E45577EDE7B7D` |
| 4 | `store-04-context-menu.png` | Organizing or removing a shortcut from its context menu | 1366 × 768 | `74369E41532199E21FE81BB2C1FB7B57987733FF4CC863818FBFEEE9E430FC08` |

The screenshots are PNG files and meet the Microsoft Store desktop screenshot
minimum of 1366 × 768. Microsoft recommends at least four screenshots and
allows up to ten. See:

- [Add and edit Store listing information](https://learn.microsoft.com/windows/apps/publish/publish-your-app/msix/add-and-edit-store-listing-info)
- [Screenshots and images](https://learn.microsoft.com/windows/apps/publish/publish-your-app/pwa/screenshots-and-images)

## Suggested captions

| File | Korean | English |
| --- | --- | --- |
| `store-01-overview.png` | 앱, 폴더, URL과 로컬 서비스를 한 화면에서 실행하세요. | Launch apps, folders, URLs, and local services from one workspace. |
| `store-02-settings.png` | 시작 프로그램, 항상 위, MIN UI와 화면 스타일을 원하는 방식으로 설정하세요. | Tune startup, always-on-top, MIN UI, and appearance to fit your workflow. |
| `store-03-add-service.png` | URL과 Health API를 등록하고 오프라인 로컬 서비스를 번들 Node.js로 시작하세요. | Register a URL and health API, then start an offline local service with the bundled Node.js runtime. |
| `store-04-context-menu.png` | 우클릭 메뉴로 바로가기를 편집하고 순서를 정리하세요. | Edit and organize shortcuts from the context menu. |

## Source map

Source captures are retained for reproducibility:

| File | Dimensions | SHA-256 |
| --- | --- | --- |
| `source/store-01-overview-source.png` | 1000 × 768 | `4D17DADE170F601715E678D029C73CF0196195C946A20F74E2FB4E0444EBE5C5` |
| `source/store-02-settings-source.jpg` | 1000 × 768 | `28348F37A8AD1BBD429B8A058974106F08B55346DAEBE3B50A8BA32EC5D7396D` |
| `source/store-03-add-service-source.jpg` | 552 × 760 | `3BA7324D6C462DE9985281B926338F9D47A759881CBE79DD7C0FE033EFF22387` |

The fourth source is
`../screenshots/workspace-widget-context-menu.jpg`; its dimensions and hash are
recorded in the screenshot inventory.

The final files use an opaque `#09162B` outer canvas and preserve each source
capture without adding marketing text, logos, device frames, or unsupported
feature claims. A few neutral desktop pixels remain inside the captured
rounded-window corners; they are opaque, non-identifying source pixels rather
than transparent canvas.

## Public-safety review

- All shortcuts use generic public examples.
- The only loopback service is `127.0.0.1:43999`.
- No user profile path, workplace project, credential, token, private hostname,
  personal contact detail, or production endpoint is visible.
- The screenshots do not claim Microsoft certification or Store availability.
