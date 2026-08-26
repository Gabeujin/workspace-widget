# Microsoft Store Partner Center 등록 및 제출 가이드

기준일: 2026-08-26

Workspace Widget의 공개 배포 경로는 **Microsoft Store용 MSIX**입니다. 저장소의
Inno Setup EXE는 로컬 개발과 이전 설치 마이그레이션 검증에만 사용하며 공개
다운로드로 배포하지 않습니다.

## 1. 개발자 계정 등록

1. [Microsoft Store 개발자 계정 시작 페이지](https://learn.microsoft.com/en-us/windows/apps/publish/get-started)를 확인한 뒤
   [신규 등록 포털](https://storedeveloper.microsoft.com/)을 엽니다.
2. 앱을 소유할 Microsoft 계정으로 Partner Center에 로그인합니다.
3. **Individual** 또는 **Company** 계정 유형을 실제 법적 주체에 맞게 선택합니다.
4. 연락처, 표시 이름, 국가/지역, 본인 또는 조직 확인 정보를 입력합니다.
5. 대시보드에서 **Apps and games** 작업영역이 열리는지 확인합니다.

개인 계정은 개인 Microsoft 계정과 정부 발급 신분증/셀피 확인이 필요할 수 있고,
회사 계정은 조직·도메인·법적 사업자 확인이 추가될 수 있습니다. 개인으로 만든
계정을 나중에 회사 계정으로 단순 전환할 수 있다고 가정하지 말고, 앱의 실제
법적 소유 주체를 먼저 정합니다.

Microsoft의 현재 신규 등록 안내상 개인과 회사 계정 온보딩은 무료입니다.
등록 과정과 확인 요구사항은 계정·국가·조직 유형에 따라 달라질 수 있으므로
[무료 계정 등록 FAQ](https://learn.microsoft.com/en-us/windows/apps/publish/faq/open-developer-account)의
현재 표시를 마지막으로 확인합니다. 계정 자체와 별개로 유료 서비스나 세금·지급
설정이 필요한 기능을 선택하면 추가 조건이 생길 수 있습니다.

## 2. 앱 이름 예약

1. Partner Center에서 **Apps and games > New product**를 선택합니다.
2. 제품 유형으로 **MSIX or PWA app**을 선택합니다.
3. `Workspace Widget` 또는 최종 상표 검토가 끝난 이름을 입력하고
   **Check availability**를 실행합니다.
4. 사용 가능하면 **Reserve product name**을 선택합니다.

예약 이름은 영구 보유가 아니므로 제출 일정을 같이 관리합니다. 자세한 동작은
[앱 이름 예약 문서](https://learn.microsoft.com/en-us/windows/apps/publish/publish-your-app/msix/reserve-your-apps-name)를
따릅니다.

## 3. 정확한 Store 패키지 ID 복사

예약 후 **Product management > Product identity**에서 다음 세 값을 그대로
복사합니다.

1. `Package/Identity/Name`
2. `Package/Identity/Publisher`
3. `Package/Properties/PublisherDisplayName`

Publisher ID, Seller ID, Store ID, Package Family Name, 마케팅 이름을 대신 넣으면
안 됩니다. 각 필드의 의미는
[앱 ID 세부정보 문서](https://learn.microsoft.com/en-us/windows/apps/publish/view-app-identity-details)에서
확인합니다.

`packaging\msix\store-identity.example.json`을 작업 PC의 별도 로컬 폴더에
복사한 뒤 세 값을 채웁니다. 실제 파일은 Git에 추가하지 않습니다.

```json
{
  "packageIdentityName": "Partner Center의 Package/Identity/Name",
  "publisher": "Partner Center의 Package/Identity/Publisher",
  "publisherDisplayName": "Partner Center의 PublisherDisplayName",
  "displayName": "Workspace Widget"
}
```

## 4. 제출 후보 빌드

먼저 보안 기준, 공개 소스, PowerShell, 네트워크 경계 검사를 실행합니다.

```powershell
.\scripts\Test-PublicSource.ps1 -WorkingTree
.\scripts\Test-PublicSourceNegativeControls.ps1
.\scripts\Test-WorkspaceWidgetNetworkBoundary.ps1
.\scripts\Test-OfficialSecurityBaseline.ps1
```

Store 후보는 검토·커밋된 clean Git checkout에서만 만듭니다. 실제 Partner Center
identity와 최신 Roslyn 컴파일러 경로를 지정합니다.

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File .\scripts\Build-WorkspaceWidgetMsix.ps1 `
  -Version 0.1.0 `
  -PackageVersion 1.0.0.0 `
  -IdentityFile C:\secure-local-config\workspace-widget-store-identity.json `
  -CompilerPath C:\path\to\Roslyn\csc.exe `
  -OutputRoot C:\WorkspaceWidgetStoreBuild\0.1.0 `
  -StoreSubmission
```

생성된 MSIX와 receipt를 다시 검증합니다.

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File .\scripts\Test-WorkspaceWidgetMsix.ps1 `
  -PackagePath <generated-msix> `
  -ReceiptPath <generated-receipt-json> `
  -IdentityFile C:\secure-local-config\workspace-widget-store-identity.json `
  -ProjectRoot . `
  -StageManifestPath <output-root>\source-build\WorkspaceWidget-0.1.0-manifest.json `
  -StoreCandidate
```

이 파일은 Store 제출용 unsigned producer artifact입니다. Store 제출 시 자체
CA 서명이 필수는 아니지만, 일반 MSIX의 설치·외부 배포에는 유효한 서명이
필요합니다. 따라서 사용자가 직접 설치할 공개 파일로 배포하지 않고,
Microsoft Store가 인증 후 다시 서명한 최종 패키지만 공개 배포합니다. 이 차이는
[Windows 앱 코드 서명 옵션](https://learn.microsoft.com/en-us/windows/apps/package-and-deploy/code-signing-options)에
설명되어 있습니다. 반대로 MSI/EXE를 Store에 연결하는 경로는 개발자가 공인
인증서로 먼저 서명해야 하므로 이 프로젝트의 공개 배포 경로가 아닙니다.

앱의 릴리스 표시는 `0.1.0`으로 유지하지만 Store package identity 버전은
`1.0.0.0`을 사용합니다. Windows 10/11 Store 패키지는 첫 번째 버전 구간이
0이면 안 되고 네 번째 구간은 Store용으로 `0`이어야 합니다. 빌드 및 검증기는
이 조건을 만족하지 않으면 실패하도록 구성하며, 제출 파일도
`WorkspaceWidget-1.0.0.0-x64.msix`처럼 패키지 버전으로 구분합니다. 자세한
규칙은 Microsoft의 [MSIX 앱 패키지 요구 사항](https://learn.microsoft.com/windows/apps/publish/publish-your-app/msix/app-package-requirements)을
참고합니다.

## 5. Windows App Certification Kit와 실기기 검증

1. 정확한 unsigned Store 후보 MSIX에 WACK 패키지 검사를 실행합니다.
2. 설치·업데이트·제거 검증이 필요하면 payload가 같은 개발 서명 복사본을
   만들거나 Store 인증 후 Microsoft가 서명한 패키지를 사용합니다.
3. 지원되는 Windows 11 x64 표준 사용자 환경에 설치합니다.
4. WebView2 Evergreen Runtime이 설치되어 있고 현재 지원되는 안정 채널인지
   확인합니다. SDK `1.0.4129.50`에서 앱이 사용하는 API와 호환되는 Runtime으로
   실행하고, 런타임이 없거나 업데이트에 실패했을 때 안내 UX도 확인합니다.
5. 첫 실행, 바로가기, 트레이, Always on top, MIN UI, WebView2 미디어, Node 시작,
   시작 앱 설정, 업데이트, 제거, 재설치를 검증합니다.
6. 같은 후보에
   [Windows App Certification Kit](https://learn.microsoft.com/en-us/windows/uwp/debug-test-perf/windows-app-certification-kit)를
   실행하고 적용 가능한 실패를 모두 해결합니다.

WACK 명령행 검사는 활성 대화형 사용자 세션의 관리자 PowerShell에서 다음처럼
실행하고 XML 결과를 release receipt와 함께 보존합니다. Microsoft의 WACK
명령행 절차는 설치되지 않은 패키지를 `-appxpackagepath`로 직접 열어 검사할 수
있으므로 Store에 올릴 정확한 unsigned 후보를 이 단계에 사용합니다. 로컬 설치
수명주기 검증에만 별도의 개발 서명 복사본이 필요할 수 있습니다.

```powershell
$appcert = "${env:ProgramFiles(x86)}\Windows Kits\10\App Certification Kit\appcert.exe"
& $appcert reset
& $appcert test `
  -appxpackagepath C:\release\store-candidate.msix `
  -reportoutputpath C:\release\WACK-0.1.0.xml
```

Docker는 Node fixture와 정적 검사에는 쓸 수 있지만 WPF 창, 트레이,
`windows.startupTask`, WindowsApps 설치·업데이트·제거, WACK, Store 인증을
대체하지 못합니다. Windows 11 VM이 없다면 현재 Windows 11 PC의 새 표준 사용자
계정이나 별도 물리 PC에서 clean lifecycle을 검증하는 것이 현실적인 대안입니다.

## 6. Partner Center 제출 작성

Partner Center에서 새 submission을 만들고 다음 섹션을 완료합니다. 현재 제출
구조는 [MSIX 앱 제출 만들기](https://learn.microsoft.com/en-us/windows/apps/publish/publish-your-app/msix/create-app-submission)를
기준으로 합니다.

### 현재 속성 화면에서 먼저 바꿀 값

첨부된 화면처럼 첫 범주가 `Utilities + tools`, 보조 범주가
`Health + fitness`로 되어 있다면 다음 권장값으로 바꿉니다.

| Partner Center 필드 | 권장 입력 | 필수 여부 | 선택 근거 |
| --- | --- | --- | --- |
| 범주(Primary category) | `Productivity` | 필수 | 앱·폴더·URL·로컬 서비스를 빠르게 실행해 작업 효율을 높이는 것이 제품의 주된 가치입니다. |
| 하위 범주(Primary subcategory) | 선택하지 않음 | 선택 | Microsoft의 현재 분류표에서 `Productivity`에는 하위 범주가 없습니다. |
| 보조 범주(Secondary category) | `Developer tools` | 선택 | Health 확인과 로컬 Node.js 서비스 시작은 개발자 작업 흐름에도 해당합니다. |
| 보조 하위 범주 | 화면에 별도 필드가 나타날 때만 `Utilities` | 선택 | `Utilities`는 `Developer tools`의 하위 범주이며 `Productivity`의 하위 범주가 아닙니다. 일반 화면에 보조 하위 범주 필드가 없으면 입력하지 않습니다. |

`Health + fitness`는 이 앱의 기능·대상과 맞지 않으므로 선택하지 않습니다.
`Utilities + tools`도 가능한 대안이지만, 첫 제출의 주 분류는 전체 런처·작업 흐름을
더 잘 설명하는 `Productivity`를 사용합니다. 제품 방향이 개발자 전용 도구로
바뀌는 경우에만 `Developer tools > Utilities`를 주 범주로 재검토합니다.

Microsoft는 범주를 필수, 하위 범주와 보조 범주를 선택 항목으로 설명합니다.
문서와 실제 화면이 다르면 제출 시점의 Partner Center 선택지를 최종 기준으로
삼고, 선택한 값을 스크린샷 또는 텍스트 receipt로 보존합니다. 현재 분류 목록은
[MSIX 앱 범주 및 하위 범주](https://learn.microsoft.com/en-us/windows/apps/publish/publish-your-app/msix/categories-and-subcategories)와
[MSIX 앱 속성 입력](https://learn.microsoft.com/en-us/windows/apps/publish/publish-your-app/msix/enter-app-properties)을
확인합니다.

### 입력 전 고정 증빙

- [ ] 제출 대상 source commit과 clean working tree를 기록합니다.
- [ ] exact MSIX 경로·SHA-256, build receipt·검증 receipt, source manifest를
      같은 release evidence 폴더에 보존합니다.
- [ ] WACK 결과와 악성코드 검사 결과가 exact MSIX를 가리키는지 확인합니다.
- [ ] 개인정보처리방침·제품·지원 URL이 HTTPS 200으로 로그인 없이 열리고,
      정책 날짜와 지원 경로가 최신인지 확인합니다.
- [ ] Store 서명 패키지가 아직 없으면 clean install/update/uninstall 결과를
      완료로 표시하지 않고 `HOLD`로 남깁니다.

### Pricing and availability

- [ ] 가격은 `Free`로 선택하고 무료 평가판·인앱 구매·구독은 사용하지 않습니다.
- [ ] 실제 지원 가능한 국가/지역만 선택합니다. 계정이 허용한다는 이유만으로
      지원할 수 없는 시장까지 자동 선택하지 않습니다.
- [ ] 대상 고객과 검색 가능성(discoverability)은 일반 Store 검색 공개를 목표로
      하되, 인증 직후 점검이 필요하면 먼저 링크 전용 또는 수동 게시 옵션을
      선택합니다.
- [ ] 게시 시점은 첫 제출에서는 수동 게시 또는 충분한 지연 시간을 두어 Store
      서명 설치본을 확인할 시간을 확보합니다.
- [ ] Partner Center가 `*`로 표시한 시장·가격·게시 일정 필드가 모두 완료되었는지
      섹션의 validation 상태로 확인합니다.

### Properties

- [ ] 범주 `Productivity`, 하위 범주 없음, 선택적 보조 범주
      `Developer tools`를 위 결정표대로 입력합니다.
- [ ] “개인정보에 접근·수집하거나 전송합니까?”에는 보수적으로 **예**를
      선택합니다. Health URL, 웹 링크, HTTPS 미디어와 YouTube 연결에서 선택한
      제3자에게 IP 주소와 요청 메타데이터가 직접 전송될 수 있기 때문입니다.
- [ ] 개인정보처리방침 URL에
      `https://gabeujin.github.io/workspace-widget/privacy/`를 입력합니다.
- [ ] 제품 웹사이트에는 `https://gabeujin.github.io/workspace-widget/`, 지원 URL에는
      `https://gabeujin.github.io/workspace-widget/support/`를 입력합니다.
- [ ] 회사 계정에서 연락처가 필수로 표시되면 실제 응답 가능한 이메일·주소 등
      법적 계정 정보를 입력합니다. 이를 공개 저장소 문서에 복사하지 않습니다.
- [ ] 계정·로그인, 광고, 개발자 텔레메트리·분석, 인앱 구매·구독,
      생성형 AI 기능은 `없음`으로 선언합니다.
- [ ] 위치·연락처·카메라·마이크·Bluetooth 접근은 `없음`으로 선언합니다.
- [ ] 지원 환경은 Windows Desktop, Windows 11 x64, 최소 OS build 22000으로
      package receipt와 일치시킵니다. WebView2 Evergreen Runtime은 선택적
      YouTube 미리보기 의존성으로 설명합니다.
- [ ] 접근성·하드웨어 선언은 실제 검증한 항목만 선택하고, 키보드 또는 포인팅
      장치를 최소 입력 장치로 기록합니다.

Workspace Widget의 공개 개인정보처리방침은
`https://gabeujin.github.io/workspace-widget/privacy/`이며, 제출 직전에 브라우저로
정상 응답과 최신 내용을 다시 확인합니다. 속성 요구사항은
[앱 속성 입력 문서](https://learn.microsoft.com/en-us/windows/apps/publish/publish-your-app/msix/enter-app-properties)를
참조합니다.

### Age ratings

- [ ] IARC의 모든 질문을 완료하고 최종 등급·질문지 receipt를 저장합니다.
- [ ] 앱 자체에는 폭력, 성적 콘텐츠, 욕설, 약물, 도박·모의 도박, 광고,
      구매, 채팅, 사용자 간 공유, 생성형 AI 기능이 없다고 실제 기능 기준으로
      답합니다.
- [ ] 사용자 지정 URL 또는 로컬 프로젝트의 외부 콘텐츠를 앱이 직접 제공하는
      콘텐츠처럼 과장하지 않습니다.
- [ ] 다만 외부 브라우저 열기와 사용자가 선택한 YouTube WebView2 미리보기가
      있으므로 Internet/external content 관련 질문은 실제 포털 문구에 맞춰
      사실대로 답합니다. 가장 낮은 등급을 얻기 위해 기능을 누락하지 않습니다.

### Packages

- [ ] clean commit에서 `-StoreSubmission`으로 만든 정확한 unsigned MSIX 하나만
      업로드합니다. 로컬 개발 서명본이나 Inno Setup EXE는 올리지 않습니다.
- [ ] 업로드 전후 MSIX SHA-256이 release receipt와 같은지 확인합니다.
- [ ] package analysis의 identity, publisher, version `1.0.0.0`, x64 architecture,
      Windows Desktop 대상, 최소 OS build 22000을 receipt와 대조합니다.
- [ ] `runFullTrust`와 `windows.startupTask` 선언이 예상대로 표시되는지 확인합니다.
- [ ] Partner Center의 `Validated` 표시는 업로드 형식 검사를 통과했다는 뜻이지,
      제출 전체 완료나 Microsoft 인증 통과를 뜻하지 않습니다.
- [ ] identity·capability warning, 예상하지 않은 device family, hash 불일치가
      있으면 제출하지 않고 원인을 수정한 새 clean commit에서 다시 빌드합니다.

### Store listings

- [ ] `docs\STORE-LISTING-KIT.md`의 검토된 `en-US`와 `ko-KR` 제품명, 짧은 설명,
      전체 설명, 기능 목록을 각각 입력합니다.
- [ ] 첫 제출의 `What's new`는 비워 둡니다. 설명 필드에는 HTML·코드·직접 URL을
      넣지 않고 제품·개인정보·지원 전용 URL 필드를 사용합니다.
- [ ] 기능 항목은 각 200자 이하, 최대 20개 제한 안에서 현재 10개 항목을
      사용하고 실제 패키지 기능과 일치시킵니다.
- [ ] Desktop 스크린샷은 최소 1장이 필요하지만, 현재 준비된 불투명 PNG 4장을
      `STORE-LISTING-KIT.md`의 순서대로 각 언어 listing에 등록합니다.
- [ ] 각 스크린샷과 앱 아이콘의 실제 Store 미리보기를 확인하고, 개인 정보,
      사내 URL·경로, 개발용 오류, 미인증 보증 표현이 없는지 확대 검토합니다.
- [ ] 제품명·패키지 표시명·설명·범주가 모두 “작업 흐름 런처”라는 주된 용도와
      일치하는지 확인합니다. Health 기능만 보고 서버 관리 제품이나 보안 제품으로
      과장해 분류하지 않습니다.
- [ ] “Microsoft가 보증한 보안 앱”처럼 인증 범위를 오해하게 하는 표현을 쓰지
      않습니다.
- [ ] 개인정보처리방침·제품·지원 URL이 로그인 없이 HTTPS로 열리고 지원 경로가
      실제로 동작하는지 다시 확인합니다.

Store listing의 필수 필드와 이미지 요구사항은
[Store listing 정보 추가 및 편집](https://learn.microsoft.com/en-us/windows/apps/publish/publish-your-app/msix/add-and-edit-store-listing-info)을
제출 직전에 다시 확인합니다.

### Submission options

`runFullTrust` restricted capability 사유에는 다음 내용을 기반으로 작성합니다.

> Workspace Widget is a user-controlled desktop launcher. It opens local apps,
> files, folders, and URLs selected by the user and can start user-selected
> local Node.js projects under the signed-in user's existing permissions. It
> does not elevate, install a service or driver, or run as SYSTEM.

사용자가 명시적으로 선택한 로컬 Node 코드만 실행하며, 원격 코드를 내려받아
자동 실행하지 않는다는 점도 적습니다. `runFullTrust` 설명과 선언 요구사항은
[앱 capability 선언 문서](https://learn.microsoft.com/en-us/windows/apps/package-and-deploy/app-capability-declarations)를
따릅니다.

인증 메모에는 다음도 함께 기록합니다.

- [ ] 계정이나 로그인이 필요 없고 Start with Windows는 기본 비활성입니다.
- [ ] 앱·파일·폴더·URL·스크립트는 사용자가 명시적으로 등록해야 실행됩니다.
- [ ] Health URL은 등록한 항목에만 사용하며 로컬 Node 자동 시작은 loopback
      Health 대상에만 허용됩니다.
- [ ] 트레이 숨김·복원·완전 종료, Always on top, MIN UI, 시작 앱 설정의 재현
      절차를 제공합니다.
- [ ] WACK 결과와 알려진 제한, 아직 남은 clean lifecycle HOLD를 사실대로
      요약합니다. 검증하지 않은 결과를 PASS로 쓰지 않습니다.

## 7. 인증 제출과 출시 후 확인

1. 언어·listing, 아이콘·스크린샷, IARC, markets·가격·게시 일정,
   restricted capability 설명을 포함해 모든 섹션의 validation warning을
   해결합니다.
2. **Submit for certification**을 누릅니다.
3. certification report의 실패·경고를 보존하고 코드/문서/패키지 수정과 연결합니다.
4. 통과 후 Store가 서명한 설치본으로 설치·업데이트·시작 앱·제거를 다시
   확인합니다.
5. Store listing의 공개 상태와 실제 설치 버튼을 확인합니다.
6. 필요할 때만
   [Package flights](https://learn.microsoft.com/en-us/windows/apps/publish/package-flights)를
   사용하며 대상, 기간, 통과 기준, 일반 배포 승격 조건을 기록합니다. Flight는
   Store 인증의 필수 단계가 아닙니다.
7. 최종 Store URL, Store-signed package identity, certification 결과, source commit,
   MSIX SHA-256, WACK 결과를 한 release receipt로 보존합니다.

최종 receipt에는 submission ID, 선택한 범주·하위 범주·보조 범주, IARC 결과,
가격·시장·게시 방식, 언어별 listing, 업로드 MSIX SHA-256, source commit, WACK,
악성코드 검사, certification report와 Store 서명 설치본 smoke test를 함께
연결합니다.

## 제출 전 최종 HOLD 조건

다음 중 하나라도 없으면 “Store 출시 완료”로 표시하지 않습니다.

- 실제 Partner Center identity
- clean commit에서 생성된 exact Store candidate와 receipt
- 최신 공식 보안 기준 PASS
- Windows 11 표준 사용자 clean install/update/uninstall PASS
- WACK PASS
- 개인정보처리방침·지원 URL live 확인
- 기본 언어와 각 언어 listing, 아이콘·스크린샷 표시 검토
- 실제 Partner Center에서 선택한 범주·하위 범주·보조 범주 receipt
- IARC, markets, 가격, 배포 일정 완료
- `runFullTrust` 설명과 인증 메모 연결, 모든 validation warning 해결
- Partner Center certification PASS
- Store listing 공개·설치 버튼 확인과 Store-signed 설치본 최종 smoke test

Store 정책은 바뀔 수 있으므로 제출 직전에
[Microsoft Store 정책](https://learn.microsoft.com/en-us/windows/apps/publish/store-policies)과
[패키지 요구사항](https://learn.microsoft.com/en-us/windows/apps/publish/publish-your-app/msix/app-package-requirements)을
다시 확인합니다.
