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
  const pkgPath = path.join(packagesDir, pkgName, 'package.json');
  
  if (fs.existsSync(pkgPath)) {
    const pkg = JSON.parse(fs.readFileSync(pkgPath, 'utf8'));
    
    // Update package version
    pkg.version = version;
    
    // Update internal workspace dependencies if they exist
    if (pkg.dependencies) {
      for (const depName in pkg.dependencies) {
        if (depName.startsWith('@dvai-edge/')) {
          // If it's a workspace dependency, we keep "workspace:*" or similar
          // but we can also ensure other fields are consistent if needed.
        }
      }
    }
    
    fs.writeFileSync(pkgPath, JSON.stringify(pkg, null, 2) + '\n');
    console.log(`- Updated ${pkgName}`);
  }
}

console.log('Version synchronization complete.');
