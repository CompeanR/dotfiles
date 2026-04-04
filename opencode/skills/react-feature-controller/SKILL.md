---
name: react-feature-controller
description: >
  Enforces Feature-Sliced Architecture with plain TypeScript controllers that own feature business logic outside React.
  Trigger: When creating new React/React Native features, refactoring screens to separate concerns, or adding feature-level state management.
license: Apache-2.0
metadata:
  author: gentleman-programming
  version: "1.0"
---

## When to Use

Use this skill when:
- Creating a new React or React Native feature with meaningful business rules.
- Refactoring a screen, hook, or component that mixes rendering with orchestration or validation.
- Adding feature-level state management that should stay local to the feature instead of moving to a global store.
- Building flows that need explicit lifecycle management, derived view models, or testable controller logic outside React.

Do **not** use this skill for:
- Pure presentational components.
- Global app-wide state that belongs in Zustand or another dedicated global store.
- One-off ephemeral UI state like `isOpen`, hover state, or a simple uncontrolled input.
- Tiny forms with fewer than 3 fields and no meaningful validation or orchestration.

---

## Critical Patterns

### Pattern 1: React is render-only

React components and custom hooks must NOT contain business logic. Screens read a View Model and dispatch controller actions. They do not orchestrate services, compute domain decisions, or talk to storage/network APIs.

```typescript
type UnlockScreenProps = {
  state: UnlockPracticeState;
  actions: {
    handleKeyPress: (key: string) => void;
    retry: () => void;
  };
};

export function UnlockScreen({ state, actions }: UnlockScreenProps) {
  if (state.status === "loading") return <LoadingView />;
  if (state.status === "error") return <ErrorView message={state.error} onRetry={actions.retry} />;

  return (
    <PracticeView
      title={state.title}
      submitLabel={state.submitLabel}
      isSubmitDisabled={state.isSubmitDisabled}
      onKeyPress={actions.handleKeyPress}
    />
  );
}
```

### Pattern 2: Controller owns feature state and lifecycle

The controller is a plain TypeScript class. It has zero React imports, owns dependencies, exposes `get state()`, supports `subscribe(listener)`, calls `notify()` after mutations, and cleans up in `dispose()`.

```typescript
export interface FeatureState {
  status: "idle" | "loading" | "ready" | "error";
  title: string;
  submitLabel: string;
  isSubmitDisabled: boolean;
  error?: string;
}

export class FeatureController {
  private readonly listeners = new Set<() => void>();
  private status: FeatureState["status"] = "idle";
  private error?: string;

  public constructor(
    private readonly service: FeatureService,
  ) {}

  public subscribe(listener: () => void): () => void {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  }

  public get state(): FeatureState {
    return {
      status: this.status,
      title: this.status === "ready" ? "Ready to practice" : "Preparing feature",
      submitLabel: this.status === "loading" ? "Loading..." : "Continue",
      isSubmitDisabled: this.status !== "ready",
      error: this.error,
    };
  }

  public async initialize(): Promise<void> {
    this.status = "loading";
    this.notify();

    try {
      await this.service.load();
      this.status = "ready";
      this.error = undefined;
    } catch (error) {
      this.status = "error";
      this.error = error instanceof Error ? error.message : "Unknown error";
    }

    this.notify();
  }

  public dispose(): void {
    this.listeners.clear();
  }

  private notify(): void {
    this.listeners.forEach((listener) => listener());
  }
}
```

### Pattern 3: Bridge hook is THIN

The bridge hook only syncs external controller state into React. It creates the controller once, subscribes, disposes, and returns delegated actions. Prefer `useSyncExternalStore` on React 18+, but the `useState` + `useEffect` bridge is acceptable.

```typescript
import { useEffect, useRef, useState } from "react";

export function useFeatureController() {
  const ref = useRef<FeatureController | null>(null);

  if (!ref.current) {
    ref.current = new FeatureController(new FeatureService());
  }

  const [state, setState] = useState(ref.current.state);

  useEffect(() => {
    const controller = ref.current!;
    const unsubscribe = controller.subscribe(() => setState(controller.state));

    void controller.initialize();

    return () => {
      unsubscribe();
      controller.dispose();
    };
  }, []);

  return {
    state,
    actions: {
      initialize: () => ref.current?.initialize(),
      submit: () => ref.current?.submit(),
      retry: () => ref.current?.initialize(),
    },
  };
}
```

### Pattern 4: Feature-Sliced folder structure is mandatory

Organize by feature boundary first, then by architectural role inside the feature.

```text
features/
  └── {feature-name}/
      ├── {feature}.controller.ts
      ├── {feature}.viewmodel.ts
      ├── {feature}.entity.ts
      ├── {feature}.service.ts
      ├── {feature}.repository.ts
      ├── {feature}.adapter.ts
      ├── __tests__/
      │   ├── {feature}.controller.test.ts
      │   ├── {feature}.entity.test.ts
      │   └── {feature}.service.test.ts
      └── components/
          └── SomePresentation.tsx
```

### Pattern 5: View Models are explicit contracts

The UI never computes domain truth. Derived booleans, labels, formatting, and display decisions belong in the controller and must be exposed through typed interfaces.

```typescript
export interface WordTokenViewModel {
  id: string;
  text: string;
  displayText: string;
  isCompleted: boolean;
  isCurrent: boolean;
  isError: boolean;
}

export interface UnlockPracticeState {
  status: "loading" | "error" | "ready";
  badgeText: string;
  keyboardVisible: boolean;
  success: boolean;
  usedFallback: boolean;
  tokens: WordTokenViewModel[];
}
```

### Pattern 6: Animations belong in the controller for React Native

Animated values are controller instance properties, not component locals. The controller exposes interpolations or animated values through the View Model so the UI only binds them.

```typescript
export class UnlockPracticeController {
  private readonly pulse = new Animated.Value(0);

  public get state(): UnlockPracticeState {
    return {
      ...this.baseState,
      animations: {
        pulseScale: this.pulse.interpolate({ inputRange: [0, 1], outputRange: [1, 1.03] }),
      },
    };
  }
}
```

---

## Decision Tree

```text
Is it a core business rule?                           → Put it in .entity.ts
Does it coordinate entities, repositories, or flows? → Put it in .service.ts
Does it call storage, network, or native APIs?       → Put it in .adapter.ts behind a .repository.ts port
Does it derive JSX-ready UI state?                   → Put it in .controller.ts
Does it render JSX?                                  → Put it in a screen/component only
Is it tiny ephemeral UI-only state?                  → Keep it in the component
Otherwise                                            → Stop and clarify the boundary before coding
```

---

## Code Examples

### Example 1: Naming and architectural roles

| Role | Suffix | Allowed Dependencies | React imports? |
|------|--------|----------------------|----------------|
| Entity | `.entity.ts` | None or pure utilities | ❌ Never |
| Repository port | `.repository.ts` | None (interface only) | ❌ Never |
| Adapter | `.adapter.ts` | SDKs, fetch, AsyncStorage, native APIs | ❌ Never |
| Service | `.service.ts` | Entities + Repositories | ❌ Never |
| Controller | `.controller.ts` | Services + Entities + Animated (RN only) | ❌ Never, except bridge hook at bottom |
| Screen/Component | `.tsx` | Controller hook only | ✅ Yes |

Naming rules:
- Files use `kebab-case` with architectural suffixes.
- Controller classes use `PascalCaseController`.
- Bridge hooks use `use{Feature}Controller`.
- State contracts use `{Feature}State`.
- Nested item view models use `{Thing}ViewModel`.

### Example 2: Anti-patterns to reject immediately

```typescript
// ❌ Wrong: business logic trapped in React
export function PracticeScreen() {
  const [score, setScore] = useState(0);

  useEffect(() => {
    if (score > 3) {
      AsyncStorage.setItem("phase", "2");
    }
  }, [score]);

  const isUnlocked = score > 3;

  return <Button disabled={!isUnlocked} />;
}

// ✅ Correct: React renders only pre-derived state
export function PracticeScreen() {
  const { state, actions } = usePracticeController();

  return <Button disabled={state.isAdvanceDisabled} onPress={actions.advanceToNextPhase} />;
}
```

---

## Commands

```bash
rg --glob '*.{ts,tsx}' 'useState|useEffect' src features app  # Find React state/effect hot spots to refactor
rg --glob '*.{ts,tsx}' 'AsyncStorage|fetch\(|axios\.|Animated\.Value' src features app  # Detect API/storage/animation leakage into UI
rg --glob '*.{ts,tsx}' 'Controller|use.*Controller' src features lib app  # Find existing controller implementations to mirror
```

---

## Resources

- **Canonical example**: `lib/unlock/UnlockPracticeController.ts` in VerseGuard shows the controller + bridge hook pattern in a real feature.
- **Supporting example layers**:
  - `lib/engine/MemorizationEngine.ts` — pure domain/entity logic
  - `lib/progression/progressionService.ts` — orchestration/service layer
  - `lib/progress/progressRepository.ts` — repository port
  - `lib/progress/asyncStorageProgressRepository.ts` — adapter implementation
