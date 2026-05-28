import { defineConfig } from 'vitest/config';
import path from 'path';

export default defineConfig({
  test: {
    globals: true,
    environment: 'node',
    include: ['packages/*/src/**/*.test.ts'],
    // The react-native package's tests are JEST tests — they use
    // `jest.mock('react-native', …)` to stub the TurboModule and rely
    // on @react-native/jest-preset to transform react-native's
    // Flow-typed source. They run under `pnpm --filter
    // @dvai-bridge/react-native test` (jest) and in CI via
    // test-react-native.yml. Vitest can't parse react-native's Flow
    // `index.js` and has no `jest.mock`, so the root vitest glob must
    // skip them. (Tests were converted vitest→jest in commit 2b3f8c7
    // but this exclude wasn't added then, leaving root `pnpm test`
    // red on these two files even though the jest workflow was green.)
    exclude: [
      '**/node_modules/**',
      '**/dist/**',
      'packages/dvai-bridge-react-native/**',
    ],
  },
});
