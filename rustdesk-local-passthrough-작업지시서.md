# RustDesk macOS 로컬 단축키 통과(Local Passthrough) 기능 구현 작업지시서

> **대상 실행 주체:** Claude Code (claude cli)
> **저장소:** `rustdesk/rustdesk` (fork 권장)
> **작성일:** 2026-06-08
> **문서 성격:** 기술 조사 결과 + 구현 작업지시서

---

## 1. 개요 (Summary)

macOS에서 RustDesk로 원격 제어 중일 때, `Ctrl + 화살표`(←/→/↑/↓)가 원격 호스트로 전송되어 로컬 Mac의 Mission Control(데스크톱/Spaces 전환)이 동작하지 않는다.

본 작업의 목표는 **지정한 키 조합(우선 `Ctrl + 화살표`)을 원격으로 보내지 않고 로컬 macOS로 통과시켜, 로컬 Spaces 전환이 정상 동작하도록** 소스를 수정하는 것이다.

조사 결과 이 기능은 **약 20줄 내외의 최소 수정**으로 구현 가능하며, 동일한 메커니즘(특정 키를 로컬로 통과)이 코드에 이미 존재해 검증되어 있다.

---

## 2. 배경 및 문제 정의 (Problem Statement)

- RustDesk 클라이언트(제어하는 측)는 `rdev` 라이브러리로 OS 레벨에서 키보드 이벤트를 후킹한다. macOS에서는 이것이 `CGEventTap` 기반으로 동작한다.
- 세션이 활성화되어 키보드가 후킹된 상태에서는 키 입력이 원격 호스트로 전송되고, 로컬 OS로는 전달되지 않는다.
- 따라서 macOS 기본 Spaces 전환 단축키인 `Ctrl + ←/→` 등이 로컬에서 동작하지 않는다.
- RustDesk에는 "특정 단축키만 로컬로 보내기" 같은 세밀한 설정이 없다.

### 목표 동작 (Desired Behavior)

| 키 입력 | 현재 동작 | 목표 동작 |
|---|---|---|
| `Ctrl + 화살표` | 원격으로 전송 | **로컬 macOS로 통과** → Spaces 전환 |
| `Ctrl + C` 등 기타 조합 | 원격으로 전송 | 원격으로 전송 (변경 없음) |
| 일반 타이핑 | 원격으로 전송 | 원격으로 전송 (변경 없음) |

---

## 3. 기술 조사 결과 (Research Findings)

### 3.1 핵심 후킹 지점

- **파일:** `src/keyboard.rs`
- **함수:** `start_grab_loop()` 내부의 `try_handle_keyboard` 클로저
- **참고 라인(변동 가능):** `keyboard.rs` 약 612행~709행 구간

### 3.2 rdev grab 콜백 반환값의 의미 (가장 중요)

`try_handle_keyboard`는 rdev grab 콜백으로, 반환값이 이벤트의 운명을 결정한다.

| 반환값 | 의미 |
|---|---|
| `Some(event)` | 이벤트를 **로컬 OS로 통과**시킨다 (로컬 앱 / Mission Control이 수신) |
| `None` | 이벤트를 **소비/차단**한다 (로컬은 수신하지 못함) |

### 3.3 현재 처리 흐름 (요약)

```rust
// CapsLock/NumLock은 로컬로 통과 (이미 존재하는 예외 처리 패턴)
if key == Key::CapsLock || key == Key::NumLock {
    return Some(event);
}

// 상대 마우스 모드 종료 단축키(macOS: Cmd+G) 차단 처리
if should_block_relative_mouse_shortcut(key, is_press) {
    return None;
}

// 핵심 로직
let res = if KEYBOARD_HOOKED.load(Ordering::SeqCst) {
    client::process_event(&get_keyboard_mode(), &event, None); // 원격 전송
    if is_press { None } else { Some(event) }   // 누름은 로컬 차단, 뗌은 통과
} else {
    Some(event)  // 후킹 안 됨 → 로컬 통과
};
```

### 3.4 이미 검증된 동일 메커니즘

1. **CapsLock 통과:** `Some(event)`를 반환해 특정 키를 로컬로 흘려보내는 패턴이 이미 존재한다.
2. **macOS Cmd+G 처리:** 상대 마우스 모드 종료 단축키가 동일 grab 루프에서 로컬 처리되도록 구현되어 있다 → **macOS grab 루프가 시스템 단축키를 로컬로 통과시키는 메커니즘이 검증되어 있음**을 의미한다.

### 3.5 modifier 상태 추적

- `MODIFIERS_STATE`(HashMap)가 Shift/Ctrl/Alt/Meta의 눌림 상태를 추적한다.
- 갱신은 `event_to_key_events()` → `update_modifiers_state()` 경로에서 이루어진다(약 922행).
- `Ctrl + 화살표` 판정 시 이 상태를 읽어 Ctrl 동시 누름 여부를 확인한다.

### 3.6 화살표 키 식별자 (rdev)

물리 화살표 키는 다음 식별자를 사용한다(numpad 변환과 별개):
`Key::UpArrow`, `Key::DownArrow`, `Key::LeftArrow`, `Key::RightArrow`

---

## 4. 구현 명세 (Implementation Spec)

### 4.1 추가할 헬퍼 함수

`src/keyboard.rs`에 아래 함수를 추가한다.

```rust
#[cfg(target_os = "macos")]
#[inline]
fn is_local_passthrough_chord(key: Key) -> bool {
    let is_arrow = matches!(
        key,
        Key::UpArrow | Key::DownArrow | Key::LeftArrow | Key::RightArrow
    );
    if !is_arrow {
        return false;
    }
    let m = MODIFIERS_STATE.lock().unwrap();
    *m.get(&Key::ControlLeft).unwrap_or(&false)
        || *m.get(&Key::ControlRight).unwrap_or(&false)
}
```

### 4.2 `try_handle_keyboard` 수정

CapsLock 가드 직후, 기존 핵심 로직 **이전**에 아래 블록을 삽입한다.

```rust
#[cfg(target_os = "macos")]
if KEYBOARD_HOOKED.load(Ordering::SeqCst) {
    // Ctrl 자체는 원격에도 보내되, 로컬 OS에도 통과시켜 로컬 단축키 chord가 성립하게 한다.
    if matches!(key, Key::ControlLeft | Key::ControlRight) {
        client::process_event(&get_keyboard_mode(), &event, None); // 원격 modifier 동기화
        return Some(event); // 로컬 OS도 Ctrl 인지
    }
    // Ctrl + 화살표는 원격으로 보내지 않고 로컬로만 통과 → Mission Control 전환
    if is_local_passthrough_chord(key) {
        return Some(event);
    }
}
```

### 4.3 동작 검증 논리

| 단계 | 로컬 macOS | 원격 호스트 |
|---|---|---|
| `Ctrl ↓` | Ctrl 인지 (통과) | Ctrl 누름 수신 |
| `← ↓` | 화살표 인지 → **Spaces 전환** | 수신 없음 |
| `← ↑` | 화살표 뗌 | 수신 없음 |
| `Ctrl ↑` | Ctrl 뗌 (통과) | Ctrl 뗌 수신 |

- **로컬:** `Ctrl↓ → ← → Ctrl↑` = 완전한 chord → Spaces 전환 정상 ✓
- **원격:** `Ctrl↓ → Ctrl↑` = 무해한 Ctrl 단독 탭(orphan 없음) ✓
- **`Ctrl + C` 등:** Ctrl이 원격에 유지되므로 정상 전송 ✓

---

## 5. Claude Code 작업 지시 (Step-by-Step)

### 단계 0. 사전 준비
- [ ] `rustdesk/rustdesk`를 fork 후 clone (또는 기존 로컬 클론 사용).
- [ ] 작업 브랜치 생성: `git checkout -b feature/macos-local-passthrough`.
- [ ] `src/keyboard.rs`에서 `start_grab_loop`, `try_handle_keyboard`, `MODIFIERS_STATE`, `KEYBOARD_HOOKED` 위치를 먼저 확인(라인 번호는 버전마다 다를 수 있음).

### 단계 1. 헬퍼 함수 추가
- [ ] 4.1의 `is_local_passthrough_chord` 함수를 `src/keyboard.rs`에 추가.
- [ ] `Key`, `MODIFIERS_STATE`가 스코프 내에서 접근 가능한지 확인.

### 단계 2. grab 콜백 수정
- [ ] 4.2 블록을 `try_handle_keyboard`의 CapsLock 가드 직후에 삽입.
- [ ] 기존 `should_block_relative_mouse_shortcut` 및 메인 로직과 충돌하지 않는 순서인지 확인(삽입 위치가 메인 로직 이전이어야 함).

### 단계 3. (선택, 권장) 옵션화
하드코딩 대신 세션 옵션 토글로 만들면 부작용을 통제할 수 있다.
- [ ] `view_only`, `server_keyboard_enabled`를 `session.lc`에서 읽는 기존 배선을 참고.
- [ ] `local_passthrough_keys`(bool) 옵션을 세션 설정에 추가.
- [ ] 4.2 블록 진입 조건에 옵션 플래그 검사 추가.
- [ ] 세션 툴바(Flutter UI)에 체크박스/토글 추가.

### 단계 4. 빌드
- [ ] macOS 소스 빌드 환경 준비: Rust 툴체인, Flutter, vcpkg 의존성(libvpx, opus, aom 등).
- [ ] RustDesk 공식 빌드 문서 절차에 따라 빌드.
- [ ] 컴파일 경고/에러 0 확인.

### 단계 5. 검증 (Acceptance Criteria)
- [ ] macOS → (임의 원격) 세션 연결 상태에서 `Ctrl + ←/→`로 **로컬** Mac의 Spaces가 전환된다.
- [ ] 같은 상태에서 `Ctrl + C`, `Ctrl + V` 등이 **원격**에서 정상 동작한다.
- [ ] 일반 텍스트 타이핑이 원격에서 정상 동작한다.
- [ ] 원격 호스트에서 화살표 키가 잘못 입력되거나 modifier가 눌린 채 남는(stuck) 현상이 없다.
- [ ] (옵션화한 경우) 토글 OFF 시 기존 동작(원격 전송)으로 복귀한다.

### 단계 6. 마무리
- [ ] 커밋 메시지: `feat(macos): pass Ctrl+Arrow to local for Mission Control`.
- [ ] 변경 요약과 검증 결과를 PR 설명에 기록.

---

## 6. 함정 및 주의사항 (Gotchas)

1. **modifier orphan 문제 (가장 중요):** 화살표만 `Some`으로 통과시키면, 직전 `Ctrl` 누름이 이미 `None`으로 로컬에서 차단되어 로컬 OS가 "Ctrl 없는 맨 화살표"만 받아 Spaces 전환이 실패한다. → **반드시 `Ctrl` 키를 로컬·원격 양쪽에 모두 흘려보내야 한다**(4.2의 Ctrl 분기).

2. **로컬 측 부작용:** Ctrl이 로컬에도 항상 전달되므로, RustDesk 창이 포커스된 상태에서 로컬 앱도 Ctrl을 인지한다. 대부분 무해(맨 Ctrl은 동작 없음)하나, 완전 통제가 필요하면 단계 3의 옵션화 권장.

3. **플랫폼 가드:** 본 수정은 `#[cfg(target_os = "macos")]`로 한정한다. Windows/Linux의 Spaces 개념·단축키는 다르므로 별도 설계 필요.

4. **라인 번호 신뢰 금지:** 본 문서의 라인 번호는 조사 시점 기준이며, `master` 갱신으로 이동할 수 있다. 함수명/심볼명으로 위치를 찾을 것.

5. **빌드 환경이 더 어려움:** 기능 수정 자체는 작지만, RustDesk macOS 소스 빌드(Rust + Flutter + vcpkg)가 더 번거로울 수 있다. 빌드 환경 세팅에 시간을 배분할 것.

---

## 7. 확장 가능성 (Optional Extensions)

- **통과 키 목록 확장:** `Cmd+Space`(스포트라이트), Mission Control 키(F3 등) 등 다른 로컬 시스템 단축키를 통과 목록에 추가.
- **사용자 정의 목록:** 통과시킬 키 조합을 설정 파일/UI에서 사용자가 지정하도록 일반화.
- **양방향 표시:** 현재 통과 모드 활성 여부를 툴바 아이콘으로 표시.

---

## 8. 빠른 체크리스트 (TL;DR)

- [ ] fork & 브랜치 생성
- [ ] `is_local_passthrough_chord` 헬퍼 추가
- [ ] `try_handle_keyboard`에 macOS 통과 블록 삽입 (Ctrl은 양쪽 전송, 화살표는 로컬만)
- [ ] (권장) 세션 옵션 토글로 전환
- [ ] macOS 빌드
- [ ] 인수 조건 5종 검증
- [ ] 커밋 & PR

---

## 부록 A. 참고 심볼 빠른 찾기

| 심볼 | 위치(파일) | 역할 |
|---|---|---|
| `start_grab_loop()` | `src/keyboard.rs` | rdev grab 루프 시작 |
| `try_handle_keyboard` (클로저) | `src/keyboard.rs` (start_grab_loop 내부) | **수정 대상** 키 이벤트 콜백 |
| `MODIFIERS_STATE` | `src/keyboard.rs` | modifier 눌림 상태 추적 |
| `update_modifiers_state()` | `src/keyboard.rs` (약 922행) | modifier 상태 갱신 |
| `KEYBOARD_HOOKED` | `src/keyboard.rs` | 세션 키보드 후킹 활성 플래그 |
| `should_block_relative_mouse_shortcut()` | `src/keyboard.rs` (약 571행) | Cmd+G 종료 단축키 차단(참고 패턴) |
| `client::process_event()` | `src/keyboard.rs` (약 321행) | 원격으로 키 이벤트 전송 |
