/**
 * Public surface of the license module. Consumed by `src/index.ts`
 * (the DVAI orchestrator) and by tests. Native SDKs re-implement the
 * same semantics in their own languages but read the same JWT format
 * and check the same claims.
 */
export { LicenseValidator } from "./LicenseValidator.js";
export type { LicenseValidatorOptions } from "./LicenseValidator.js";
export {
  isPaidTier,
  type DvaiLicensePayload,
  type DvaiPlatform,
  type LicenseStatus,
  type LicenseTier,
} from "./types.js";
export {
  DEFAULT_LICENSE_FILENAME,
  type LicenseDiscoveryOptions,
} from "./discovery.js";
export {
  DVAI_PUBLIC_KEYS,
  PLACEHOLDER_KID,
  type DvaiPublicKeyJwk,
} from "./publicKeys.js";
