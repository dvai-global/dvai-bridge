// Minimal ambient module declaration for `react-test-renderer`. Upstream
// `@types/react-test-renderer` was deprecated for React 19; the built-in
// types in `react/jsx-runtime` and `react`'s own `act` cover most flows
// today. We only use the legacy `TestRenderer.create` API in our hook
// test, so a structural declaration is enough.
declare module "react-test-renderer" {
  export interface ReactTestRenderer {
    unmount(): void;
    toJSON(): unknown;
    update(element: unknown): void;
    root: unknown;
  }
  export function create(element: unknown, options?: unknown): ReactTestRenderer;
  // `act` re-export — React 19 ships its own `act` from "react".
  export function act(callback: () => void | Promise<void>): Promise<void>;
}
