import { defineConfig } from "vitepress";
import llmstxt from "vitepress-plugin-llms";

export default defineConfig({
	title: "DVAI-Bridge",
	description: "One local OpenAI server, embedded in your Web, iOS, Android, React Native, Flutter, or .NET app. Six SDKs, nine backends, one HTTP surface.",
	// Site is served at https://bridge.deepvoiceai.co/docs/ — Apache vhost
	// proxies the root to the Fastify portal and serves /docs/* directly
	// from /var/www/dvai-bridge-docs/. Without this, VitePress emits
	// root-relative asset URLs (/assets/...) which 404 because they hit
	// the Fastify proxy instead of the static-files alias.
	base: "/docs/",
	head: [
		[
			"script",
			{
				defer: "defer",
				src: "https://app.lemonsqueezy.com/js/lemon.js",
			},
		],
		// head entries are emitted verbatim — VitePress does NOT apply
		// `base` to user-supplied href values. Prefix manually.
		["link", { rel: "icon", href: "/docs/favicon.png", type: "image/x-png" }],
	],
	// Ignore dead links that point outside the published docs tree:
	// - `../../CHANGELOG` from `docs/migration/*.md` resolves to the repo-root
	//   CHANGELOG.md (not a VitePress page).
	// - Planning docs under `docs/superpowers/` contain illustrative markdown
	//   samples that reference sibling docs from a different on-disk location;
	//   they are design artifacts, not part of the published site.
	ignoreDeadLinks: [
		/CHANGELOG(\.md)?$/,
		/^\/?superpowers\//,
		/superpowers\/(specs|plans)\//,
		/^\.\.\/guide\/transports/,
	],
	cleanUrls: true,
	vite: {
		// We ship our own hand-curated `docs/llms.txt` + `docs/llms-full.txt`
		// (see `docs/guide/ai-agents.md` for why). The plugin's per-page
		// `.md` mirroring is still useful, but the auto-generated index +
		// concatenated files would clobber ours, so they're disabled here.
		plugins: [
			llmstxt({
				generateLLMsTxt: false,
				generateLLMsFullTxt: false,
			}),
		],
	},
	markdown: {
		linkify: false,
		image: {
			lazyLoading: true,
		},
	},
	srcExclude: ["superpowers/**", "marketing/**"],
	themeConfig: {
		logo: "/logo.png",
		nav: [
			{ text: "Guide", link: "/guide/introduction" },
			{ text: "Reference", link: "/reference/api" },
			{ text: "GitHub", link: "https://github.com/dvai-global/dvai-bridge" },
		],
		sidebar: [
			{
				text: "Guide",
				items: [
					{ text: "Introduction", link: "/guide/introduction" },
					{ text: "Getting Started", link: "/guide/getting-started" },
					{ text: "Backends", link: "/guide/backends" },
					{ text: "Transports", link: "/guide/transports" },
					{ text: "Native LLM (Capacitor)", link: "/guide/native-backend" },
					{ text: "Capacitor Quickstart", link: "/guide/quickstart-capacitor" },
					{ text: "iOS Native SDK", link: "/guide/ios-native-sdk" },
					{ text: "Android Native SDK", link: "/guide/android-native-sdk" },
					{ text: "React Native SDK", link: "/guide/react-native-sdk" },
					{ text: "Flutter SDK", link: "/guide/flutter-sdk" },
					{ text: ".NET SDK", link: "/guide/dotnet-sdk" },
					{ text: "MLX Backend", link: "/guide/mlx-backend" },
					{ text: "Model Distribution", link: "/guide/model-distribution" },
					{ text: "Multimodal", link: "/guide/multimodal" },
					{ text: "Tested Models", link: "/guide/tested-models" },
					{ text: "Auto-Recovery & Robustness", link: "/guide/auto-recovery" },
					{ text: "Distributed Inference (v3.0)", link: "/guide/distributed-inference" },
					{ text: "Self-Hosting Rendezvous (v3.0)", link: "/guide/self-hosting-rendezvous" },
					{ text: "DVAI Hub (v3.1)", link: "/guide/dvai-hub" },
					{ text: "DVAI Hub — Developer Fork (v3.1)", link: "/guide/dvai-hub-developer-fork" },
					{ text: "Example apps", link: "/guide/examples" },
					{ text: "Vibe-coding with DVAI-Bridge", link: "/guide/ai-agents" },
					{ text: "vs. Other Tools", link: "/guide/comparison" },
				],
			},
			{
				text: "License setup",
				collapsed: false,
				items: [
					{ text: "Overview", link: "/guide/license/" },
					{ text: "Web", link: "/guide/license/web" },
					{ text: "Node", link: "/guide/license/node" },
					{ text: "iOS", link: "/guide/license/ios" },
					{ text: "Android", link: "/guide/license/android" },
					{ text: ".NET", link: "/guide/license/dotnet" },
					{ text: "Flutter", link: "/guide/license/flutter" },
					{ text: "React Native", link: "/guide/license/react-native" },
					{ text: "Capacitor", link: "/guide/license/capacitor" },
					{ text: "Pre-init inspection", link: "/guide/license/pre-init-inspection" },
				],
			},
			{
				text: "API Reference",
				items: [
					{ text: "Core Options", link: "/reference/api" },
					{ text: "React Hooks", link: "/reference/react" },
					{ text: "Vanilla JS", link: "/reference/vanilla" },
				],
			},
			{
				text: "Migration Guides",
				items: [
					{ text: "v3.x → v4.0", link: "/migration/v3-to-v4" },
					{ text: "v3.0 → v3.1", link: "/migration/v3.0-to-v3.1" },
					{ text: "v2.4 → v3.0", link: "/migration/v2.4-to-v3.0" },
					{ text: "v2.3 → v2.4", link: "/migration/v2.3-to-v2.4" },
					{ text: "v2.2 → v2.3", link: "/migration/v2.2-to-v2.3" },
					{ text: "v2.1 → v2.2", link: "/migration/v2.1-to-v2.2" },
					{ text: "v2.0 → v2.1", link: "/migration/v2.0-to-v2.1" },
					{ text: "v1.6 → v2.0", link: "/migration/v1.6-to-v2.0" },
					{ text: "v1.5 → v1.6", link: "/migration/v1.5-to-v1.6" },
				],
			},
			{
				text: "Contributing",
				items: [
					{ text: "iOS native", link: "/development/contributing-ios" },
					{ text: "Android native", link: "/development/contributing-android" },
					{ text: "React Native", link: "/development/contributing-react-native" },
					{ text: "Flutter", link: "/development/contributing-flutter" },
					{ text: ".NET", link: "/development/contributing-dotnet" },
				],
			},
			{
				text: "Development",
				items: [
					{ text: "Testing", link: "/development/testing" },
					{ text: "Handler Parity", link: "/development/handler-parity" },
					{ text: "Mac Remote Builds", link: "/development/mac-remote-builds" },
					{ text: "Distributed Inference Testing (v3.0+)", link: "/development/distributed-inference-testing" },
					{ text: "v3.1 Development Notes", link: "/development/v3.1-development-notes" },
				],
			},
		],
		socialLinks: [
			{ icon: "github", link: "https://github.com/dvai-global/dvai-bridge" },
		],
		footer: {
			message: "Released under Custom License.",
			copyright:
				'Copyright © 2024-present <a href="https://deepvoiceai.co" target="_blank" rel="noopener">Deep Voice AI Limited</a>',
		},
	},
});
