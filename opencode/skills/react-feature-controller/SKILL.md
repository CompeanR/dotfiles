---
name: react-feature-controller
description: >
    Enforces Feature-Sliced Architecture with plain TypeScript controllers, a service registry ($S), and a generic useController hook for React/React Native projects.
    Trigger: When creating new React/React Native features, refactoring screens to separate concerns, or adding feature-level state management.
license: Apache-2.0
metadata:
    author: gentleman-programming
    version: "2.2"
---

## When to Use

Use this skill when:

- Creating a new React or React Native feature with meaningful business rules.
- Refactoring a screen, hook, or component that mixes rendering with orchestration or validation.
- Adding feature-level state management that should stay local to the feature instead of moving to a global store.
- Building flows that need explicit lifecycle management, derived view models, or testable controller logic outside React.
- Setting up service infrastructure for a new project (registry, boot file).

Do **not** use this skill for:

- Pure presentational components.
- Global app-wide state that belongs in Zustand or another dedicated global store.
- One-off ephemeral UI state like `isOpen`, hover state, or a simple uncontrolled input.
- Screens with no business logic (just haptics + navigate) — those don't need a controller.

---

## Critical Patterns

### Pattern 1: React is render-only

Screens read state and call controller methods directly. No business logic in screens. No derived computations. No service calls.

```tsx
import { useController } from "../../hooks/useController";
import { PaywallController } from "../../features/paywall/paywall.controller";

export default function PaywallScreen() {
    const router = useRouter();
    const { state, controller } = useController(() => new PaywallController({ toSuccess: () => router.replace("/unlock") }));

    return (
        <View>
            {state.plans.map((plan) => (
                <PlanCard key={plan.id} onSelect={() => controller.selectPlan(plan.id)} />
            ))}
            <PrimaryButton
                title={state.primaryLabel}
                onPress={() => controller.purchaseSelectedPlan()}
                disabled={state.status === "purchasing"}
            />
        </View>
    );
}
```

### Pattern 2: Controller owns feature state and lifecycle

The controller is a plain TypeScript class. Zero React imports. Exposes `get state()`, `subscribe(listener)`, `dispose()`, and optional `initialize()`. Calls `notify()` after mutations.

```typescript
export interface FeatureState {
    status: "idle" | "loading" | "ready" | "error";
    title: string;
    isSubmitDisabled: boolean;
    error?: string;
}

export class FeatureController {
    private readonly listeners = new Set<() => void>();
    private status: FeatureState["status"] = "idle";
    private error?: string;

    constructor(private readonly navigation: FeatureNavigation) {}

    public subscribe(listener: () => void): () => void {
        this.listeners.add(listener);
        return () => this.listeners.delete(listener);
    }

    public get state(): FeatureState {
        return {
            status: this.status,
            title: this.status === "ready" ? "Ready" : "Loading...",
            isSubmitDisabled: this.status !== "ready",
            error: this.error,
        };
    }

    public async initialize(): Promise<void> {
        this.status = "loading";
        this.notify();

        try {
            await $S(FeatureService).load();
            this.status = "ready";
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

### Pattern 3: useController — generic lifecycle hook

One generic hook handles all controller lifecycle. No custom `useXxxController` hooks. The screen calls `useController(factory)` directly.

```typescript
// hooks/useController.ts
interface Controllable<TState> {
    readonly state: TState;
    subscribe(listener: () => void): () => void;
    dispose(): void;
    initialize?(): void;
}

export function useController<C extends Controllable<C["state"]>>(factory: () => C): { state: C["state"]; controller: C } {
    const controllerRef = useRef<C | null>(null);

    if (!controllerRef.current) {
        controllerRef.current = factory();
    }

    const controller = controllerRef.current;
    const [state, setState] = useState(controller.state);

    useEffect(() => {
        const unsubscribe = controller.subscribe(() => setState(controller.state));
        controller.initialize?.();

        return () => {
            unsubscribe();
            controller.dispose();
        };
    }, []);

    return { state, controller };
}
```

Usage in screens:

```tsx
const router = useRouter();
const { state, controller } = useController(() => new CommitmentController({ toNext: () => router.push("/onboarding/next") }));
```

### Pattern 4: Three dependency rules

Controllers access dependencies through three mechanisms. No other patterns.

| Dependency type | Mechanism                                           | Example                                                                                |
| --------------- | --------------------------------------------------- | -------------------------------------------------------------------------------------- |
| **Stores**      | Direct class property                               | `private store = useSubscriptionStore;` then `this.store.getState().setEntitlement(e)` |
| **Services**    | Service registry                                    | `$S(SubscriptionService).purchase(pkg)`                                                |
| **Navigation**  | Constructor injection (only remaining injected dep) | `constructor(private readonly navigation: { toSuccess: () => void })`                  |

```typescript
import { $S } from "../../services/registry";
import { SubscriptionService } from "../subscription/subscription.service";
import { useSubscriptionStore } from "../subscription/subscription.store";

interface PaywallNavigation {
    toSuccess: () => void;
}

export class PaywallController {
    private subscription = useSubscriptionStore; // store: direct
    private onboarding = useOnboardingStore; // store: direct

    constructor(private readonly navigation: PaywallNavigation) {} // nav: injected

    async purchaseSelectedPlan() {
        this.subscription.getState().setPurchaseStatus("pending");
        const result = await $S(SubscriptionService).purchase(plan.packageIdentifier); // service: $S()
        this.subscription.getState().setEntitlement(result.entitlement);
        this.navigation.toSuccess();
    }
}
```

### Pattern 5: Service registry ($S) + Bootable interface

One global registry. Services registered at boot. Resolved by class reference. Services that need async initialization implement `Bootable`.

```typescript
// services/registry.ts

/**
 * Services that need async initialization implement this.
 * Standardized: every service uses bootstrap(), no ad-hoc method names.
 */
export interface Bootable {
    bootstrap(): Promise<unknown>;
}

const instances = new Map<Function, any>();

export function $S<T>(Service: new (...args: any[]) => T): T {
    const instance = instances.get(Service);
    if (!instance) throw new Error(`Service not registered: ${Service.name}. Did you call bootServices()?`);
    return instance;
}

export function register<T>(Service: new (...args: any[]) => T, instance: T): void {
    instances.set(Service, instance);
}

export function _resetServicesForTests(): void {
    instances.clear();
}
```

### Pattern 6: boot.ts is the composition root

`services/boot.ts` owns ALL service creation, adapter wiring, and bootstrap orchestration. Service classes are pure — they do NOT create their own adapters or singletons. The boot file is the ONLY place that knows which adapter goes with which service.

```typescript
// services/boot.ts
import { $S, register } from "./registry";
import { SubscriptionService } from "../features/subscription/subscription.service";
import { RevenueCatAdapter } from "../features/subscription/revenuecat.adapter";
import { getRevenueCatApiKey } from "../features/subscription/revenuecat.config";

let _bootstrapPromise: Promise<void> | null = null;

/**
 * Create and register all app services. Sync, runs once.
 */
export function bootServices(): void {
    register(SubscriptionService, new SubscriptionService(new RevenueCatAdapter(), getRevenueCatApiKey));
    // Future: register(AnalyticsService, new AnalyticsService({ ... }));
}

/**
 * Bootstrap all services that need async initialization.
 * Idempotent — subsequent calls return the same promise.
 * Each service handles its own store writes on success/failure.
 */
export function bootstrapServices(): Promise<void> {
    if (_bootstrapPromise) return _bootstrapPromise;
    _bootstrapPromise = Promise.all([
        bootstrapSubscription(),
        // Future: $S(AnalyticsService).bootstrap(),
    ]).then(() => {});
    return _bootstrapPromise;
}
```

```typescript
// app/_layout.tsx — two calls, nothing else
bootServices();

export default function RootLayout() {
    useEffect(() => {
        void bootstrapServices();
    }, []);
    // ...
}
```

Key rules:

- **`bootServices()`** is sync — registers service instances. Called at module scope before any screen renders.
- **`bootstrapServices()`** is async — runs `bootstrap()` on services that need it. Called in `useEffect`. Idempotent (safe for React Strict Mode).
- **Services are pure classes** — they receive a `SubscriptionPort` interface, NOT a `RevenueCatAdapter`. They don't know which adapter they're using.
- **boot.ts STAYS THIN** — register services + trigger bootstrap. That's it. Retry logic, listener wiring, foreground refresh, throttling — all that belongs in a feature-owned `{feature}.runtime.ts`, NOT in boot.ts.
- **NEVER put feature-specific runtime behavior in boot.ts.** If bootstrap needs retry with backoff, that logic lives in `features/{feature}/{feature}.runtime.ts`, and boot.ts just calls it.

### Pattern 7: Feature-Sliced folder structure

Organize by feature boundary first, then by architectural role.

**HARD RULE: `features/` contains ONLY `.ts` files. NEVER `.tsx`.** No React components, no JSX, no React imports. If you need a React component for a feature, it goes in `components/` (shared) or inline in the screen file in `app/`.

```text
features/
  └── {feature-name}/
      ├── {feature}.controller.ts       # Pure TS class — NEVER React
      ├── {feature}.entity.ts           # Domain types and pure logic
      ├── {feature}.service.ts          # Orchestration layer
      ├── {feature}.runtime.ts          # Lifecycle orchestration (bootstrap, listeners, refresh)
      ├── {feature}.port.ts             # Port (interface only)
      ├── {feature}.adapter.ts          # Adapter (implements port)
      ├── {feature}.store.ts            # Zustand store (if global state needed)
      └── __tests__/
          └── {feature}.controller.test.ts

components/                             # Shared presentational React components
  └── SomeButton.tsx

hooks/
  └── useController.ts                  # Generic lifecycle hook (one per project)

services/
  ├── registry.ts                       # $S() resolver
  └── boot.ts                           # Composition root — STAYS THIN (see Pattern 6)
```

**Boundary violations to REJECT:**

- ❌ `features/subscription/PremiumGate.tsx` → React component inside features/
- ❌ `features/subscription/BillingBanner.tsx` → React component inside features/
- ❌ Any `.tsx` file under `features/` for any reason

### Pattern 8: View Models are explicit contracts

The UI never computes domain truth. Derived booleans, labels, formatting belong in the controller.

```typescript
export interface PaywallState {
    status: "loading" | "ready" | "purchasing" | "restoring" | "error";
    plans: Plan[];
    selectedPlanId: PlanId;
    primaryLabel: string; // "Start 7-day trial" or "Subscribe now"
    secondaryLabel: string; // "Continue with limited access"
    canContinueFree: boolean;
    errorMessage?: string;
}
```

### Pattern 9: Animations belong in the controller (React Native)

Animated values are controller properties, exposed through the state object.

```typescript
export class StreakPreviewController {
    private readonly animations = {
        flameScale: new Animated.Value(0),
        heroOpacity: new Animated.Value(0),
    };

    public get state(): StreakPreviewState {
        return {
            animations: this.animations,
            // ...
        };
    }
}
```

### Pattern 10: No controller for trivial screens

If a screen has no state, no lifecycle, and no derived computations — just haptics and navigation — it does NOT need a controller. Put the logic directly in the screen.

```tsx
// ✅ Correct: trivial action, no controller needed
export default function ChartInsightScreen() {
    const router = useRouter();

    const handleContinue = () => {
        Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Light);
        useOnboardingStore.getState().setCurrentOnboardingStep("success");
        router.push("/onboarding/next");
    };

    return <PrimaryButton onPress={handleContinue} />;
}
```

---

## Decision Tree

```text
Is there NO business logic (just haptic + navigate)?  → No controller. Logic in screen.
Is it a core business rule?                           → Put it in .entity.ts
Does it coordinate entities, repositories, or flows?  → Put it in .service.ts
Does it call storage, network, or native APIs?        → Put it in .adapter.ts behind a .port.ts port
Does it derive JSX-ready UI state?                    → Put it in .controller.ts
Does it render JSX?                                   → Put it in a screen/component only
Is it tiny ephemeral UI-only state?                   → Keep it in the component
Otherwise                                             → Stop and clarify the boundary before coding
```

---

## Code Examples

### Naming and architectural roles

| Role       | Suffix           | Allowed Dependencies                       | React imports?               |
| ---------- | ---------------- | ------------------------------------------ | ---------------------------- |
| Entity     | `.entity.ts`     | None or pure utilities                     | Never                        |
| Port       | `.port.ts`       | None (interface only)                      | Never                        |
| Adapter    | `.adapter.ts`    | SDKs, fetch, AsyncStorage, native APIs     | Never                        |
| Service    | `.service.ts`    | Entities + Repositories                    | Never                        |
| Store      | `.store.ts`      | Zustand, entities                          | Never (Zustand is not React) |
| Controller | `.controller.ts` | `$S()` + Stores + Entities + Animated (RN) | Never                        |
| Screen     | `.tsx`           | `useController` + Controller class         | Yes                          |

Naming rules:

- Files use `kebab-case` with architectural suffixes.
- Controller classes use `PascalCaseController`.
- State contracts use `{Feature}State`.
- Navigation interfaces use `{Feature}Navigation`.
- Nested item view models use `{Thing}ViewModel`.

### Anti-patterns to reject

```typescript
// ❌ Business logic in screen
export function PracticeScreen() {
    const [score, setScore] = useState(0);
    useEffect(() => {
        if (score > 3) AsyncStorage.setItem("phase", "2");
    }, [score]);
    return <Button disabled={score <= 3} />;
}

// ❌ Custom useXxxController hook wrapping useController
export function usePaywallController() {
    return useController(() => new PaywallController(...));
}
// Why wrong: unnecessary indirection. Call useController directly in the screen.

// ❌ Service injected through constructor
new PaywallController({ purchase: (pkg) => service.purchase(pkg) });
// Why wrong: use $S(SubscriptionService).purchase(pkg) inside the controller.

// ❌ Store injected through constructor lambda
new PaywallController({ getOffering: () => useSubscriptionStore.getState().offering });
// Why wrong: controller should access store directly as a class property.

// ❌ Singleton created inside the service file
// subscription.service.ts
let _instance: SubscriptionService | null = null;
export function getSubscriptionRuntime() { ... }
// Why wrong: service files are pure classes. Singleton creation belongs in services/boot.ts.

// ❌ Service creates its own adapter
export class SubscriptionService {
    private adapter = new RevenueCatAdapter();  // service knows about concrete adapter
}
// Why wrong: service depends on the interface (SubscriptionPort), not the adapter. boot.ts wires them.

// ❌ Subscribing to Zustand and discarding the value for "reactivity"
export function PremiumGate({ feature }: Props) {
    useSubscriptionStore((state) => state.entitlement.state); // subscribed but unused!
    const hasAccess = isPremiumFeature(feature);               // reads getState() separately
}
// Why wrong: if you need reactive state, USE the return value. If you need a snapshot, use getState().

// ❌ Calling $S() directly from a React component
function BillingBanner() {
    const handleManage = () => $S(SubscriptionService).manageSubscription();
}
// Why wrong: React components should receive callbacks as props or use a controller.
// The screen or layout owns the $S() call and passes it down.

// ❌ Putting a React component (.tsx) inside features/
// features/subscription/BillingBanner.tsx
// Why wrong: features/ is ZERO React. Components go in components/ or inline in app/ screens.

// ✅ Correct
const { state, controller } = useController(
    () => new PaywallController({ toSuccess: () => router.replace("/unlock") }),
);
```

---

## Commands

```bash
rg --glob '*.{ts,tsx}' 'useState|useEffect' features app     # Find React state/effect leaking into business logic
rg --glob '*.{ts,tsx}' 'AsyncStorage|fetch\(|axios\.' features app  # Detect API/storage leakage into controllers
rg --glob '*.controller.ts' 'useRouter|useEffect|useState'   # Controller files must NOT have React imports
rg --glob '*.controller.ts' 'private notify'                 # Find controllers with real state (have notify)
rg --glob '*.controller.ts' -L 'private notify'              # Find controllers WITHOUT notify (may not need to be classes)
```

---

## Resources

- **Canonical example**: `features/paywall/paywall.controller.ts` — controller with `$S()`, direct stores, navigation injection
- **Supporting layers**:
    - `features/subscription/subscription.entity.ts` — pure domain types
    - `features/subscription/subscription.service.ts` — pure service class (no singleton, no adapter imports)
    - `features/subscription/subscription.port.ts` — port (interface)
    - `features/subscription/revenuecat.adapter.ts` — adapter implementation (only file importing SDK)
    - `features/subscription/subscription.store.ts` — Zustand store
- **Infrastructure**:
    - `hooks/useController.ts` — generic lifecycle hook
    - `services/registry.ts` — `$S()` service registry + `Bootable` interface
    - `services/boot.ts` — composition root (creates services, wires adapters, bootstraps)
