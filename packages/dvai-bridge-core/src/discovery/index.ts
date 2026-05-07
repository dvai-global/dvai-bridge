/**
 * Public surface for the discovery module.
 */

export type { Peer, DiscoveryEvent, IDiscovery } from "./types.js";
export { MDNS_SERVICE_TYPE } from "./types.js";
export { StaticDiscovery } from "./static.js";
export { CompositeDiscovery, createMdnsDiscovery } from "./composite.js";
export { BrowserMdnsDiscovery } from "./mdns-browser.js";
// Node-only — re-exported lazily; importing this in a browser bundle
// will tree-shake away cleanly when discovery isn't used.
export type { AdvertisedTxt } from "./mdns-node.js";
