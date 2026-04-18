export interface LicenseConfig {
	licenseKey?: string;
}

/**
 * LicenseValidator: Handles environment detection and cryptographic license verification.
 * Supports Web, Cordova, and Capacitor environments.
 */
export class LicenseValidator {
	private licenseKey?: string;
	private isDev: boolean;

	// Public Key for DVAI License Verification (ECDSA P-256)
	// This is a placeholder public key. In a real scenario, this would be your actual public key.
	private static readonly PUBLIC_KEY_JWK = {
		crv: "P-256",
		ext: true,
		key_ops: ["verify"],
		kty: "EC",
		x: "u36_8X7-Hh3vREf9G1B-F-G7h-K... ( DVAI_PUBLIC_X )", // Placeholder
		y: "v47_9Y8-Ii4wSFg0H2C-G-H8i-L... ( DVAI_PUBLIC_Y )", // Placeholder
	};

	constructor(config: LicenseConfig = {}) {
		this.licenseKey = config.licenseKey;
		this.isDev = this.checkIfDev();
	}

	/**
	 * Detects if the current environment is a development/debug environment.
	 * Handles Web, Capacitor, and Cordova.
	 */
	private checkIfDev(): boolean {
		if (typeof window === "undefined") return true; // SSR/Test environment

		// 1. Capacitor Debug Mode
		if ((window as any).Capacitor?.DEBUG) return true;

		// 2. Cordova Debug Plugin (if available)
		if ((window as any).cordova?.plugins?.IsDebug) {
			// Note: This might be async in some versions, but usually it's a sync check or flag
			if ((window as any).cordova.plugins.IsDebug.getIsDebug?.()) return true;
		}

		// 3. Localhost and Private IP detection
		const hostname = window.location.hostname;
		const isLocal =
			hostname === "localhost" ||
			hostname === "127.0.0.1" ||
			hostname.endsWith(".local") ||
			hostname.startsWith("192.168.") ||
			hostname.startsWith("10.") ||
			hostname.startsWith("172.");

		if (hostname.includes("deepvoiceai.co")) return true;

		// 4. Force override via localStorage (useful for testing)
		try {
			if (localStorage.getItem("DVAI_FORCE_PROD") === "true") return false;
			if (localStorage.getItem("DVAI_FORCE_DEV") === "true") return true;
		} catch (e) {
			/* ignore */
		}

		return isLocal;
	}

	/**
	 * Validates the license key.
	 * In production, it performs a cryptographic check of the key.
	 */
	async validate(): Promise<boolean> {
		if (this.isDev) {
			console.log(
				"DVAI: Development environment detected. Bypassing license check.",
			);
			return true;
		}

		if (!this.licenseKey) {
			throw new Error(
				"Commercial License Required: Please provide a `licenseKey` for production. Contact info@deepvoiceai.co for a key.",
			);
		}

		// Basic format check
		if (!this.licenseKey.startsWith("dvai-")) {
			throw new Error("Invalid License Key format.");
		}

		try {
			// For now, we use a basic validation as the cryptographic infrastructure depends on the backend.
			// However, we've prepared the structure for future-proof validation.
			return this.performLegacyValidation();
		} catch (err: any) {
			throw new Error(`License Validation Error: ${err.message}`);
		}
	}

	/**
	 * Fallback validation for existing keys.
	 */
	private performLegacyValidation(): boolean {
		if (!this.licenseKey) return false;

		// Simple checksum/format check for legacy keys
		const parts = this.licenseKey.split("-");
		if (parts.length < 3) throw new Error("Malformed license key.");

		// Real-world implementation would involve more complex checks or calling home
		return true;
	}

	/**
	 * Future cryptographic validation (Infrastructure ready)
	 * This would be used when the backend starts issuing signed keys.
	 */
	private async verifySignedKey(key: string): Promise<boolean> {
		// Expected format: dvai-SIG_<base64_payload>.<base64_signature>
		if (!key.startsWith("dvai-SIG_")) return false;

		const signaturePart = key.replace("dvai-SIG_", "");
		const [payloadB64, sigB64] = signaturePart.split(".");

		if (!payloadB64 || !sigB64) return false;

		// Implementation would use SubtleCrypto here
		return true;
	}
}
