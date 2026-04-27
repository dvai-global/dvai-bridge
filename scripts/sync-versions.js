import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const rootPkgPath = path.resolve(__dirname, '../package.json');
const packagesDir = path.resolve(__dirname, '../packages');

// Read root version
const rootPkg = JSON.parse(fs.readFileSync(rootPkgPath, 'utf8'));
const version = rootPkg.version;

console.log(`Syncing version ${version} to all packages...`);

// Get all sub-packages
const packages = fs.readdirSync(packagesDir);

for (const pkgName of packages) {
  const pkgDir = path.join(packagesDir, pkgName);
  if (!fs.statSync(pkgDir).isDirectory()) continue;

  let updated = false;

  // 1. package.json — npm-graph integration. Every package has one.
  const pkgPath = path.join(pkgDir, 'package.json');
  if (fs.existsSync(pkgPath)) {
    const pkg = JSON.parse(fs.readFileSync(pkgPath, 'utf8'));
    pkg.version = version;
    // Internal workspace deps are tracked via "workspace:*" so we don't
    // rewrite them here; this hook is reserved for any future per-dep
    // pinning logic.
    if (pkg.dependencies) {
      for (const _depName in pkg.dependencies) {
        // intentionally empty
      }
    }
    fs.writeFileSync(pkgPath, JSON.stringify(pkg, null, 2) + '\n');
    updated = true;
  }

  // 2. pubspec.yaml — Flutter packages. Top-level `version:` line.
  const pubspecPath = path.join(pkgDir, 'pubspec.yaml');
  if (fs.existsSync(pubspecPath)) {
    const before = fs.readFileSync(pubspecPath, 'utf8');
    // Match `version: <semver>` at column 0; preserve any trailing comment.
    const after = before.replace(
      /^version:\s+\S+(\s*#[^\n]*)?$/m,
      `version: ${version}$1`,
    );
    if (after !== before) {
      fs.writeFileSync(pubspecPath, after);
      updated = true;
    }
  }

  // 3. Android `gradle.properties` — `dvaiBridgeVersion` Gradle prop.
  //    Drives both this module's `publishing { version = ... }` and the
  //    Phase 3D umbrella AAR coordinate it pulls (`co.deepvoiceai:
  //    dvai-bridge:$dvaiBridgeVersion`). Every Android-bearing package has
  //    one of these (5 cores + RN bridge + Flutter bridge currently).
  const androidGradleProps = path.join(pkgDir, 'android', 'gradle.properties');
  if (fs.existsSync(androidGradleProps)) {
    const before = fs.readFileSync(androidGradleProps, 'utf8');
    const after = before.replace(
      /^dvaiBridgeVersion=.+$/m,
      `dvaiBridgeVersion=${version}`,
    );
    if (after !== before) {
      fs.writeFileSync(androidGradleProps, after);
      updated = true;
    }
  }

  // 4. Build-script default fallback in build.gradle. Some Android
  //    modules read `project.findProperty('dvaiBridgeVersion') ?: '<x.y.z>'`
  //    where the literal default tracks the current release. Update that
  //    too so a fresh checkout without `gradle.properties` still resolves
  //    the right version.
  const androidBuildGradle = path.join(pkgDir, 'android', 'build.gradle');
  if (fs.existsSync(androidBuildGradle)) {
    const before = fs.readFileSync(androidBuildGradle, 'utf8');
    const after = before.replace(
      /(project\.findProperty\('dvaiBridgeVersion'\)\s*\?:\s*)'\d+\.\d+\.\d+'/,
      `$1'${version}'`,
    );
    if (after !== before) {
      fs.writeFileSync(androidBuildGradle, after);
      updated = true;
    }
  }

  // Note: Podspecs (.podspec) read their version dynamically from
  // package.json (`s.version = package['version']`), so they auto-track
  // step 1 and don't need a separate replace here. If a podspec ever
  // uses a literal version string, refactor it to the package['version']
  // pattern instead of adding a new sed-like rule here.

  if (updated) {
    console.log(`- Updated ${pkgName}`);
  }
}

console.log('Version synchronization complete.');
