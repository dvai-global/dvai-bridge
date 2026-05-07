const path = require('path');
const { getDefaultConfig, mergeConfig } = require('@react-native/metro-config');

// pnpm + monorepo: Metro needs explicit paths to traverse the workspace
// node_modules tree (.pnpm hoist + parent node_modules) and to watch
// workspace packages so changes to @dvai-bridge/* sources are picked up
// without a republish.
//
// References:
//   https://reactnative.dev/docs/metro#monorepo-support
//   https://pnpm.io/symlinked-node-modules-structure

const projectRoot = __dirname;
const monorepoRoot = path.resolve(projectRoot, '../..');

const defaultConfig = getDefaultConfig(projectRoot);

const config = {
  watchFolders: [monorepoRoot],
  resolver: {
    nodeModulesPaths: [
      path.resolve(projectRoot, 'node_modules'),
      path.resolve(monorepoRoot, 'node_modules'),
    ],
    // pnpm hoists peer-deps under each package's own node_modules; the
    // default resolver doesn't deduplicate them so we let unstable
    // hierarchical lookup find the closest copy first.
    unstable_enableSymlinks: true,
    unstable_enablePackageExports: true,
  },
};

module.exports = mergeConfig(defaultConfig, config);
