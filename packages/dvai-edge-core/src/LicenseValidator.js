export class LicenseValidator {
  constructor(config = {}) {
    this.licenseKey = config.licenseKey;
    this.isDev = this.checkIfDev();
  }

  checkIfDev() {
    if (typeof window === "undefined") return true; // Node environment (SSR/Tests)
    const hostname = window.location.hostname;
    return (
      hostname === "localhost" ||
      hostname === "127.0.0.1" ||
      hostname.endsWith(".local") ||
      hostname.startsWith("192.168.") // Local network testing
    );
  }

  async validate() {
    // 1. Development bypass
    if (this.isDev) {
      console.log("DvAI: Development environment detected. Bypassing license check.");
      return true;
    }

    // 2. Production check
    if (!this.licenseKey) {
      throw new Error(
        "Commercial License Required: Please provide a `licenseKey` for production domains. Contact info@deepvoiceai.co for a key."
      );
    }

    // 3. Local Key Format Validation (Basic Regex)
    if (!/^dvai-.*-.*$/.test(this.licenseKey)) {
      throw new Error("Invalid License Key format.");
    }

    // 4. Remote Validation (Optional/Future)
    // You would typically call your endpoint here:
    // const res = await fetch('https://deepvoiceai.co/api/validate', {
    //   method: 'POST',
    //   body: JSON.stringify({ key: this.licenseKey, domain: window.location.hostname })
    // });
    // if (!res.ok) throw new Error("License validation failed.");

    return true;
  }
}
